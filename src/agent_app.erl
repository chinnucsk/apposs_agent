-module(agent_app).

-behaviour(application).

%% Application callbacks
-export([start/2, stop/1]).
-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").
-endif.

%% ===================================================================
%% Application callbacks
%% ===================================================================

start(_StartType, _StartArgs) ->
  recover:start(),
  {ok, Center_url} = application:get_env(apposs_agent, center_url),
  {ok, Responder_mod} = application:get_env(apposs_agent, responder_mod),
  {ok, Pull_delay} = application:get_env(apposs_agent, pull_delay),
  {ok, Pid} = agent_sup:start_link(Center_url, Responder_mod, Pull_delay),
  {ok, Rooms} = application:get_env(apposs_agent, rooms),
  lists:foreach(fun(Room) ->
    error_logger:info_msg("add puller: ~p - ~p~n", [Center_url, Room]),
    supervisor:start_child(puller_sup,[Center_url, Room])
  end, Rooms),
  {ok, Pid}.

stop(_State) ->
  agent_sup:stop(),
  recover:stop(),
  ok.
