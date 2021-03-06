-module(client).
-behaviour(gen_fsm).
%% ------------------------------------------------------------------
%% API Function Exports
%% ------------------------------------------------------------------

-export([start/2, start_link/2, stop/1, reconnect/1, check_host/1, add_cmd/2, clean_cmds/1, pause/1, interrupt/1, reset/1]).

%% ------------------------------------------------------------------
%% gen_fsm Function Exports
%% ------------------------------------------------------------------

-export([init/1, disconnected/2, connecting/2, normal/2, run/2, paused/2, handle_event/3,
         handle_sync_event/4, handle_info/3, terminate/3,
         code_change/4]).

-ifdef(TEST).
-compile(export_all).
-endif.

-define(SERVER(Host), list_to_atom(Host ++ "@" ++ atom_to_list(?MODULE))).
-record(state, {host,
                get_host_info_fun,          % 获取主机信息的方法
                conn_params,                % 链接参数
                cm,                         % connectionManager
                handler,                    % 链接通道的句柄
                current_cmd,                % 当前正在执行的指令 
                datas=[],                   % 当前指令返回的信息，包含标准输出和标准错误
                cmd_exit_status,            % 当前指令的返回码
                exec_mod=ssh_executor,      % 指令执行器
                cmds=[]                     % 未执行的指令队列
               }).

%% ------------------------------------------------------------------
%% API Function Definitions
%% ------------------------------------------------------------------

start(Host, GetHostInfoFun) ->
  gen_fsm:start({local, ?SERVER(Host)}, ?MODULE, [Host, GetHostInfoFun], []).

start_link(Host, GetHostInfoFun) ->
  gen_fsm:start_link({local, ?SERVER(Host)}, ?MODULE, [Host, GetHostInfoFun], []).

check_host(Host) ->
  case erlang:whereis(?SERVER(Host)) of
    undefined -> no_host;
    Pid -> Pid
  end.

interrupt(Host) ->
  gen_fsm:send_all_state_event(?SERVER(Host), interrupt).

reconnect(Host) ->
  gen_fsm:send_all_state_event(?SERVER(Host), reconnect).

pause(Host) ->
  gen_fsm:send_all_state_event(?SERVER(Host), pause).

reset(Host) ->
  gen_fsm:send_all_state_event(?SERVER(Host), reset).

add_cmd(Host, Cmd) ->
  gen_fsm:send_all_state_event(?SERVER(Host), {add_cmd, Cmd}).

clean_cmds(Host) ->
  gen_fsm:send_all_state_event(?SERVER(Host), clean_cmds).

stop(Host) ->
  gen_fsm:sync_send_all_state_event(?SERVER(Host), stop).

%% ------------------------------------------------------------------
%% gen_fsm Function Definitions
%% ------------------------------------------------------------------

init([Host, GetHostInfoFun]) ->
  Cmds = recover:recover(?SERVER(Host), []),
  State = #state{host = Host,
                 get_host_info_fun=GetHostInfoFun,
                 cmds = Cmds
                },
  error_logger:info_msg("machine[~p] init~n", [Host]),
  gen_fsm:send_event(?SERVER(Host), connect),
  {ok, connecting, State, 10000}.

%% 状态机自身状态迁移逻辑
connecting(timeout, #state{host=Host, exec_mod=ExecMod, cmds=Cmds, cm=Cm}=State) ->
  error_logger:info_msg("machine[~p] connecting timeout: cmds=~p~n", [Host, Cmds]),
  recover:save(?SERVER(Host), Cmds),
  ExecMod:terminate(Cm),
  (responder:machine_on_caller(client))(Host, disconnect),
  {next_state, disconnected, State};
connecting(connect, #state{host=Host, exec_mod=ExecMod}=State) ->
  %% reconnect 会尽可能恢复正常，不管之前是否pause，重连后都是normal
  error_logger:info_msg("machine[~p] connect...~n", [Host]),
  case State#state.cm of
    undefined -> ok;
    OldCm -> ExecMod:terminate(OldCm)
  end,
  case create_connection_manager(Host, State#state.get_host_info_fun) of
    {ok, Cm, ExecMod, Params} ->
      %% 成功连接的机器统一发送reset
      (responder:machine_on_caller(client))(Host, reset),
      gen_fsm:send_event(?SERVER(Host), do_cmd),
      error_logger:info_msg("machine[~p] change state: connecting -> normal: ~p~n", [Host, State]),
      {next_state, normal, State#state{cm=Cm, conn_params=Params, exec_mod=ExecMod}};
    {error, Why} ->
      %% 连接失败的机器统一反馈disconnect
      error_logger:error_msg("machine[~p] connect fail: ~p~n", [Host,Why]),
      (responder:machine_on_caller(client))(Host, disconnect),
      %% 连接失败后进程依然保留，以便可以忽略后续指令
      {next_state, disconnected, State}
  end.

normal(do_cmd, #state{host=Host, cmds=[]}=State) ->
  error_logger:info_msg("machine[~p] get do_cmd when normal: cmds=[]~n", [Host]),
  {next_state, normal, State};
normal(do_cmd, #state{host=Host, cm=Cm, cmds=[Cmd|T_cmds], exec_mod=ExecMod}=State) ->
  error_logger:info_msg("machine[~p] get do_cmd when normal: CurrentCmd=~p, Cmds=~p~n", [Host, Cmd, T_cmds]),
  (responder:run_caller(client))(Host, Cmd),
  Handler = ExecMod:exec(Cm, Cmd),
  {next_state, run, State#state{current_cmd=Cmd, cmds=T_cmds, handler=Handler}};
normal(Event, #state{host=Host}=State) ->
  error_logger:info_msg("machine[~p] is normal state, ignore ~p~n", [Host, Event]),
  {next_state, normal, State}.

run(timeout, #state{host=Host, exec_mod=ExecMod, cmds=Cmds, cm=Cm}=State) ->
  error_logger:info_msg("machine[~p] get timeout when run: cmds=~p~n", [Host, Cmds]),
  recover:save(?SERVER(Host), Cmds),
  ExecMod:terminate(Cm),
  (responder:machine_on_caller(client))(Host, disconnect),
  {next_state, disconnected, State};
run(Event, #state{host=Host}=State) ->
  error_logger:info_msg("machine[~p] is run state, ignore ~p~n", [Host, Event]),
  {next_state, run, State}.

paused(Event, #state{host=Host}=State) ->
  error_logger:info_msg("machine[~p] is paused state, ignore ~p~n", [Host, Event]),
  {next_state, paused, State}.

disconnected(Event, #state{host=Host}=State) ->
  error_logger:info_msg("machine[~p] disconnected, ignore ~p~n", [Host, Event]),
  {next_state, disconnected, State}.


%% handle event专用于处理外部用户事件
handle_event(interrupt, StateName, #state{host=Host, cm=Cm, current_cmd=Cmd, exec_mod=ExecMod, datas=Datas}=State) ->
  case StateName of
    disconnected -> 
      error_logger:info_msg("machine[~p] is disconnected, ignore interrupt", [Host]),
      {next_state, disconnected, State};
    connecting ->
      error_logger:info_msg("machine[~p] is connecting, ignore interrupt", [Host]),
      {next_state, connecting, State};
    _ -> 
      error_logger:info_msg("machine[~p] get interrupt when ~p~n", [Host,StateName]),
      ExecMod:terminate(Cm),
      case Cmd of
        undefined -> 
          NextState = State;
        _ -> 
          {_, NextState} = finish_cmd(disconnected, State#state{cmd_exit_status=1, datas=["User interrupt." | Datas]})
      end,
      %% 为了便于查找问题，需要忠实反馈每一个disconnect状态
      (responder:machine_on_caller(client))(Host, disconnect),
      {next_state, disconnected, NextState#state{cm=undefined}}
  end;
handle_event(reconnect, StateName, #state{host=Host}=State) ->
  error_logger:info_msg("machine[~p] get reconnect when ~p~n", [Host,StateName]),
  gen_fsm:send_event(?SERVER(Host), connect),
  {next_state, connecting, State, 10000};
handle_event(pause, StateName, #state{host=Host}=State) ->
  error_logger:info_msg("machine[~p] get pause when ~p.~n", [Host,StateName]),
  case StateName of
    normal -> 
      (responder:machine_on_caller(client))(Host, pause),
      {next_state, paused, State};
    _ -> 
      error_logger:info_msg("machine[~p] is ~p state, ignore pause~n", [Host, StateName]),
      {next_state, StateName, State}
  end;
handle_event(reset, StateName, #state{host=Host, current_cmd=Cmd}=State) ->
  case StateName of
    %% disconnected 状态需要重新连接，连接后再更新机器状态
    disconnected ->
      error_logger:info_msg("machine[~p] get reset when disconnected, it will be reconnect~n", [Host]),
      gen_fsm:send_event(?SERVER(Host), connect),
      {next_state, connecting, State};
    paused ->
      %% paused状态不需要重连，因此直接callback更新机器状态
      (responder:machine_on_caller(client))(Host, reset),
      %% 如果尚未结束的指令，则变为run状态，否则是normal状态并发送do_cmd
      %% (附：有可能是pause并马上reset，此时先前的命令还未执行结束)
      case Cmd of
        undefined -> 
          error_logger:info_msg("machine[~p] get reset when paused.~n", [Host]),
          gen_fsm:send_event(?SERVER(Host), do_cmd),
          {next_state, normal, State};
        _ ->
          error_logger:info_msg("machine[~p] get reset when paused: current_cmd=~p~n", [Host, Cmd]),
          {next_state, run, State}
      end;
    _ -> 
      error_logger:info_msg("machine[~p] is ~p, ignore reset~n", [Host, StateName]),
      {next_state, StateName, State}
  end;
handle_event({add_cmd, Cmd}, StateName, #state{host=Host, current_cmd=CurrentCmd, cmds=Cmds}=State) ->
  case StateName of
    disconnected -> 
      error_logger:info_msg("machine[~p] disconnected, ignore add", [Host]),
      (responder:cb_caller(client))(Host, Cmd, {false, "not connected, please reconnect or call administrator"}),
      {next_state, disconnected, State};
    _ -> 
      case lists:member(Cmd, Cmds) orelse CurrentCmd =:= Cmd of
        true -> 
          {next_state, StateName, State};
        false ->
          New_all_cmds = lists:append(Cmds, [Cmd]),
          error_logger:info_msg("machine[~p] get add_cmd when ~p: cmd=~p, all=~p~n", [Host, StateName, Cmd, New_all_cmds]),
          gen_fsm:send_event(?SERVER(Host), do_cmd),
          {next_state, StateName, State#state{cmds=New_all_cmds}}
      end
  end;
handle_event(clean_cmds, StateName, #state{host=Host, cmds=Cmds}=State) ->
  error_logger:info_msg("machine[~p] get clean_cmds when ~p, discard=~p", [Host, StateName, Cmds]),
  {next_state, StateName, State#state{cmds=[]}}.

handle_sync_event(stop, _From, StateName, #state{host=Host}=State) ->
  error_logger:info_msg("machine[~p] get stop when ~p.", [Host, StateName]),
  {stop, normal, ok, State}.

handle_info({_Pid, not_connected, {error, etimedout}}, StateName, #state{host=Host, current_cmd=CurrentCmd, cmds=Cmds}=State) ->
  error_logger:error_msg("machine[~p] connect fail: etimedout, all commands will be ignored.", [Host]),
  case CurrentCmd of
    undefined -> done;
    _ -> 
      error_logger:error_msg("ignored: ~p",[CurrentCmd]),
      (responder:cb_caller(client))(Host, CurrentCmd, {false, "not connected"})
  end,
  lists:foreach(
    fun(Cmd) -> 
        error_logger:error_msg("ignored: ~p",[Cmd]),
        (responder:cb_caller(client))(Host, Cmd, {false, "not connected"})
    end,
    Cmds
  ),
  error_logger:info_msg("machine [~p] connect fail~n", [Host]),
  (responder:machine_on_caller(client))(Host, disconnect),
  {next_state, StateName, State#state{cmds=[], current_cmd=undefined}};

handle_info(Info, StateName, #state{cm=Cm, handler=Handler, datas=Datas, exec_mod=ExecMod}=State) ->
  try ExecMod:handle_info(Info, Cm, Handler) of
    {data, Data} ->
      {next_state, StateName, State#state{datas=[Data | Datas]},10000};
    {exit_status, ExitStatus} ->
      {next_state, StateName, State#state{cmd_exit_status=ExitStatus},10000};
    eof ->
      % 如果被interrupt，有可能接受不到eof消息，所以不在这里反转和拼接消息，而是放在closed中。 
      {next_state, StateName, State,10000};
    closed ->
      {NextState, NewState} = finish_cmd(StateName, State),
      {next_state, NextState, NewState,10000}
  catch 
    error:function_clause -> 
      error_logger:warning_msg("~p recv msg: ~p, StateName=~p, State=~p~n", [?MODULE, Info, StateName, State]),
      {next_state, StateName, State}
  end.

terminate(_Reason, _StateName, #state{host=Host, exec_mod=ExecMod, cmds=Cmds, cm=Cm}=_State) ->
  error_logger:info_msg("machine[~p] is terminated, cmds=~p~n", [Host, Cmds]),
  recover:save(?SERVER(Host), Cmds),
  ExecMod:terminate(Cm),
  (responder:machine_on_caller(client))(Host, disconnect),
  ok.

code_change(_OldVsn, StateName, State, _Extra) ->
  {ok, StateName, State}.

%% ------------------------------------------------------------------
%% Internal Function Definitions
%% ------------------------------------------------------------------
create_connection_manager(Host, GetHostInfoFun) ->
  case GetHostInfoFun(Host) of
    [] ->
      {error, no_host_info};
    Params ->
      ExecMod = get_exec_mod(Params),
      case ExecMod:conn_manager(Host, Params) of
        {ok, Cm} ->
          {ok, Cm, ExecMod, Params};
        {error, Why} ->
          {error, Why}
      end
  end.

finish_cmd(CurrentState, #state{host=Host, current_cmd=Cmd, cmd_exit_status=ExitStatus, datas=Datas}=State) ->
  Msg = lists:append(lists:reverse(Datas)),
  IsOk = ExitStatus == 0,
  error_logger:info_msg("machine[~p] cmd callback, cmd=~p, result={~p, ~ts}~n", [Host, Cmd, IsOk, Msg]),
  (responder:cb_caller(client))(Host, Cmd, {IsOk, string:sub_string(Msg,1,51200)}), %% max body size: 51200
  NextState = case CurrentState of
    run ->
      case IsOk of
        true ->
          error_logger:info_msg("machine[~p] cmd callback true, run -> normal.~n", [Host]),
          gen_fsm:send_event(?SERVER(Host), do_cmd),
          normal;
        false ->
          error_logger:info_msg("machine[~p] cmd callback false, run -> paused, why=~ts~n", [Host, Msg]),
          paused
      end;
    _ -> 
      error_logger:info_msg("machine[~p] cmd callback, state: ~p.~n", [Host,CurrentState]),
      CurrentState
  end,
  {NextState, State#state{handler=undefined, current_cmd=undefined, datas=[], cmd_exit_status=undefined}}.

get_exec_mod(Params) ->
  case proplists:get_value(adapter, Params) of
    undefined -> ssh_executor;
    Exec -> list_to_atom(Exec ++ "_executor")
  end.
