-module(puller_sup).
-behaviour(supervisor).
-export([start_link/1,init/1]).

start_link(Delay_time) ->
  supervisor:start_link({local, ?MODULE}, ?MODULE, [Delay_time]).

init([Delay_time]) ->
  % 所有的puller共用一个http通道
  http_channel_sup:start_child(puller),
  ProcessSpec = {
    puller,
    {puller,start_link,[Delay_time]},
    transient,
    2000,
    worker,
    [puller]
  },
  {ok,{{simple_one_for_one,10,100}, [ProcessSpec]}}.

