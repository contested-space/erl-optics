-module(erl_optics_server).

-behaviour(gen_server).

-export([init/1,
         handle_call/3,
         handle_cast/2,
         handle_info/2,
         terminate/2,
         code_change/3]).

-export([start_link/2,
         poll/0,
         stop/0,
         send_metrics/0,
         start_carbon/1]).

%for prototyping only
-export([start/0, value_to_carbon_string/1, poll_map_to_string/1]).

-define(SERVER, ?MODULE).

-record(state, {port, lsock}).


%%%=========
%%% API
%%%=========

%Modes: request | {timer_poll, interval=integer()}

start_link(Port, Mode) ->
    gen_server:start_link({local, ?SERVER}, ?MODULE, [Port, Mode], []).

poll() ->
    gen_server:call(?SERVER, poll).

send_metrics() ->
    gen_server:call(?SERVER, send_metrics).

stop() ->
    gen_server:cast(?SERVER, stop).

start_carbon(Interval) ->
    gen_server:cast(?SERVER, {start_carbon, Interval}).
%    timer:send_interval(Interval, timed_poll).


%%%==========
%%% Callbacks
%%%==========

init([Port, Mode]) ->
    %inets:start(),
    %{ok, Hostname} = inet:gethostname(), %remember to use this at some point
    %io:format(Hostname),
    case Mode of
        {timer_poll, Interval} ->
            timer:send_interval(Interval, carbon_poll),
            {ok, #state{}, 0};
        request ->
            {ok, LSock} = gen_tcp:listen(Port, [{active, true}]),
            {ok, _Sock} = gen_tcp:accept(LSock),
            {ok, #state{port = Port, lsock = LSock}, 0}
    end.


handle_call(poll, _From, State) ->
    {reply, erl_optics:poll(), State};

handle_call(send_metrics, _From, State) ->
        {reply, httpc:request("http://www.erlang.org"), State}.

handle_cast(stop, State) ->
    {stop, normal, State};
handle_cast({start_carbon, Interval}, State) ->
    timer:send_interval(Interval, carbon_poll),
    {noreply, State}.

handle_info(timeout, State) ->
    {noreply, State};
handle_info({tcp, Socket, RawData}, State) ->
    io:format("info received\n"),
    io:format("Raw data: "),
    io:format(RawData),
    io:format("\n"),
    R = re:replace(RawData, "\r\n$", "", [{return, list}]),
    case R of
        "prometheus" ->
            io:format(prometheus_polling()),
            gen_tcp:send(Socket, "prometheus_polling called\n");
        _ ->
            gen_tcp:send(Socket, "something useful\n")
    end,
    {noreply, State};

handle_info(carbon_poll, State) ->
    io:format("Timed polling happens\n"),
    {ok, Map} = erl_optics:poll(),
    io:format(poll_map_to_string(Map)),
    {noreply, State}.
    %% [{_, Key} | _] = maps:keys(Map),
    %% io:fwrite(Key),
    %% {noreply, State}.

terminate(_Reason, _State) ->
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.



%%%===================
%%% Internal functions
%%%===================

prometheus_polling() ->
    {Ok, Map} = erl_optics:poll(),
    maps:keys(Map).

value_to_carbon_string({Key, Val}) ->
    {Prefix, Name} = Key,
    {Type, Value} = Val,
    {ok, Hostname} = inet:gethostname(),
    case Type of
        counter ->
            list_to_binary([Prefix, $.,
                            Hostname, $.,
                            Name, 32, %32 is the space character
                            integer_to_binary(Value), 10]); %10 is the endline
        gauge ->
            list_to_binary([Prefix, $.,
                            Hostname, $.,
                            Name, 32, %32 is the space character
                            float_to_binary(Value), 10]); %10 is the endline
        dist ->
            list_to_binary(lists:flatten([[Prefix, $.,
                               Hostname, $.,
                               Name, $.,
                               atom_to_binary(K, latin1),
                               32,
                               case K of
                                   n ->
                                       integer_to_binary(V);
                                   _ ->
                                       float_to_binary(V)
                               end,
                               10] || {K, V}  <- maps:to_list(Value)]));
        histo ->
            list_to_binary(lists:flatten([[Prefix, $.,
                               Hostname, $.,
                               Name, $.,
                               case K of
                                   below ->
                                       atom_to_binary(K, latin1);
                                   above ->
                                       atom_to_binary(K, latin1);
                                   Other when is_float(Other) ->
                                       float_to_binary(Other);
                                   Error ->
                                       Error
                               end, 32,
                               integer_to_binary(V),
                               10] || {K, V}  <- maps:to_list(Value)]));

        quantile ->
            list_to_binary(lists:flatten([[Prefix, $., Hostname, $., Name, $.,
                               atom_to_binary(K, latin1), 32,
                               case K of
                                   quantile ->
                                       float_to_binary(V);
                                   sample ->
                                       float_to_binary(V);
                                   sample_count ->
                                       integer_to_binary(V);
                                   count ->
                                       integer_to_binary(V);
                                   Err -> Err
                               end, 10] ||  {K, V} <- maps:to_list(Value)]));
        Other ->
            {error, {Other, "not a lens type"}}
    end.

poll_map_to_string(Map) ->
    Str_map = maps:map(fun(K, V) -> value_to_carbon_string({K, V}) end, Map),
    list_to_binary(lists:flatten(maps:values(Str_map))).






start() ->
    Lenses = [
        erl_optics_lens:counter(<<"bob_the_counter">>),
        erl_optics_lens:dist(<<"bob_the_dist">>),
        erl_optics_lens:gauge(<<"bob_the_gauge">>),
        erl_optics_lens:histo(<<"bob_the_histo">>, [10.0, 20.0, 30.0, 40.0]),
        erl_optics_lens:quantile(<<"bob_the_quantile">>, 0.5, 0.5, 0.5)
    ],
    erl_optics:start(<<"test">>, Lenses).
