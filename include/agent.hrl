-define(INFO(Str), error_logger:info_msg(Str)).
-define(INFO(Str, Args), error_logger:info_msg(Str, Args)).
-define(WARN(Str), error_logger:warning_msg(Str)).
-define(WARN(Str, Args), error_logger:warning_msg(Str, Args)).
-define(ERROR(Str), error_logger:error_msg(Str)).
-define(ERROR(Str, Args), error_logger:error_msg(Str, Args)).