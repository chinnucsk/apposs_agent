-module(web_tests).
-include_lib("eunit/include/eunit.hrl").

web_test() ->
  inets:start(),
  web:start_link(default),
  ?assertMatch({ok, _Result}, web:http_get(default, "http://www.baidu.com")).
