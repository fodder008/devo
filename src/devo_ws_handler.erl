-module(devo_ws_handler).
-behaviour(cowboy_websocket_handler).

-export([init/3]).
-export([websocket_init/3]).
-export([websocket_handle/3]).
-export([websocket_info/3]).
-export([websocket_terminate/3]).

-record(state, {
               count =1          :: integer(),
               cmd   = undefined :: any(),
               nodes =[]         :: [node()],
               data  = []        :: any()
              }).                        

init({tcp, http}, _Req, _Opts) ->
    {upgrade, protocol, cowboy_websocket}.

websocket_init(_TransportName, Req, _Opts) ->
    register(devo, self()),
    {ok, Req, #state{}}.

websocket_handle({text, <<"stop">>}, Req, State) ->
    Cmd = State#state.cmd, 
    Nodes = State#state.nodes,
    stop_profiling(Cmd, Nodes),
    {shutdown, Req, State};
websocket_handle({text, <<"start">>}, Req, State) ->
    io:format("Profiling started ...\n"),
    {ok, Req, State};
websocket_handle({text, Msg}, Req, State) ->
    MsgStr=binary_to_list(Msg),
    case string:tokens(MsgStr, ":") of 
        ["start_profile",Feature, NodeStr] ->
            Nodes= string:tokens(NodeStr, ";"),
            Ns = [list_to_atom(N)||N<-Nodes],
            Cmd = list_to_atom(Feature),
            start_profiling(Cmd, Ns),
            NewState=State#state{cmd=Cmd, nodes=Ns},
            {ok, Req, NewState};
        _ ->
            Msg = "Unexpected message from client:"++ binary_to_list(Msg),
            {reply, {text,list_to_binary(Msg)}, State}
    end;
websocket_handle(_Data, Req, State) ->
    {ok, Req, State}.


websocket_info({timeout, _Ref, stop_profile}, Req, State) ->
    {shutdown, Req, State};
websocket_info({timeout, _Ref, _Msg}, Req, State) ->
    Cnt = State#state.count,
    StateStr=case lists:member(State#state.cmd,
                               [migration, rq_migration])
             of 
                 true ->
                     Data = [{From, To, Times}||
                                {{From, To}, Times}<-State#state.data],
                     lists:flatten(
                       io_lib:format("{~.3f,~p}.", 
                                     [Cnt*200/1000,Data]));
                 false ->
                     lists:flatten(
                       io_lib:format("{~.3f,~p}.", 
                                     [Cnt*200/1000,
                                      State#state.data]))
             end,
    erlang:start_timer(200, self(), <<"timeout">>),
    {reply, {text, list_to_binary(StateStr)}, Req, 
     State#state{count=Cnt+1, data=[]}};
websocket_info({trace_inter_node, From, To,MsgSize}, Req, State=#state{data=Data}) ->
    Key = {From, To},
    NewData=case lists:keyfind(Key, 1, Data) of
                false ->
                    [{{From, To},1, MsgSize}|Data];
                {_, Count, SumSize} ->
                    lists:keyreplace({From, To}, 1, 
                                     Data, {Key, Count+1, MsgSize+SumSize})
            end,
    {ok, Req, State#state{data=NewData}};
websocket_info({trace_rq, FromRq, ToRq}, Req, State=#state{data=Data}) ->
    Key = {FromRq, ToRq},
    NewData=case lists:keyfind(Key, 1, Data) of
                 false ->
                     [{{FromRq, ToRq},1}|Data];
                 {_, Count} ->
                     lists:keyreplace({FromRq, ToRq}, 1, 
                                      Data, {Key, Count+1})
             end,
    {ok, Req, State#state{data=NewData}};
websocket_info(_Info={run_queues_info, Ts, Rqs}, Req, State) ->
    Str=lists:flatten([" "++integer_to_list(Len)++" "
                       ||Len<-tuple_to_list(Rqs)]),
    InfoStr=lists:flatten(io_lib:format("~p ~s", [Ts, Str])),
    {reply, {text, list_to_binary(InfoStr)}, Req, State};
websocket_info(Info={s_group, _Node, _Fun, _Args}, Req, State) ->
    InfoStr=lists:flatten(io_lib:format("~p.", [Info])),
    {reply, {text, list_to_binary(InfoStr)}, Req, State};

websocket_info(Info={cpu, _Cpu}, Req, State) ->
    InfoStr=lists:flatten(io_lib:format("~p.", [Info])),
    {reply, {text, list_to_binary(InfoStr)}, Req, State};
websocket_info(start_profile, Req, State) ->
    erlang:start_timer(1, self(), <<"Online profiling started...!">>),
    {ok, Req, State};
websocket_info(stop_profile, Req, State) ->
    self()!stop_profile,
    {ok, Req, State};
websocket_info(Info, Req, State) ->
    io:format("Devo_ws_handler:unexpected trace:~p\n", [Info]),
    {ok, Req, State}.

websocket_terminate(_Reason, _Req, _State) ->
	ok.


start_profiling(rq, [Node|_]) ->
    case rpc:call(Node, erlang, system_info, [cpu_topology]) of 
        {badrpc, Reason} ->
            io:format("Devo failed to start profiling for reason:\n~p\n",
                      [Reason]);
        Cpu ->
            self()!{cpu, Cpu},
            Res=rpc:call(Node, devo_sampling, start,
                         [[run_queues], infinity, none, {devo, node()}]),
            case Res of 
                {badrpc, Reason} ->
                    io:format("Devo failed to start profiling for reason:\n~p\n",
                              [Reason]);
                _ -> Res
            end
    end;
start_profiling(migration, [Node|_]) ->
    case rpc:call(Node, erlang, system_info, [cpu_topology]) of 
        {badrpc, Reason} ->
            io:format("Devo failed to start profiling for reason:\n~p\n",
                      [Reason]);
        Cpu ->
            self()!{cpu, Cpu},
            erlang:start_timer(1, self(), <<"Online profiling started...!">>),
            devo_trace:start_trace(migration, Node, {devo, node()})
    end;
start_profiling(rq_migration, [Node|_]) ->
    case rpc:call(Node, erlang, system_info, [cpu_topology]) of 
        {badrpc, Reason} ->
            io:format("Devo failed to start profiling for reason:\n~p\n",
                      [Reason]);
        Cpu ->
            self()!{cpu, Cpu},
            erlang:start_timer(1, self(), <<"Online profiling started...!">>),
            Res=rpc:call(Node, devo_sampling, start,
                         [[run_queues], infinity, none,{devo, node()}]),
            case Res of 
                {badrpc, Reason} ->
                    io:format("Devo failed to start profiling for reason:\n~p\n",
                              [Reason]);
                _ -> 
                    devo_trace:start_trace(migration, Node, {devo, node()})
            end
    end;
start_profiling(inter_node, Nodes) ->
    erlang:start_timer(1, self(), <<"Online profiling started...!">>),
    devo_trace:start_trace(inter_node, Nodes, {devo, node()});
start_profiling(s_group, Nodes) ->
    devo_trace:start_trace(s_group, Nodes, {devo, node()});
start_profiling(Cmd, _Nodes) ->
    io:format("start_profiling: unnexpected command:~p\n", [Cmd]),
    ok.


stop_profiling(rq, [Node|_]) ->
    Res=rpc:call(Node, devo_sampling, stop,[]),
    case Res of 
        {badrpc, Reason} ->
            io:format("Devo failed to stop profiling for reason:\n~p\n",
                      [Reason]);
        _ -> 
           Res
    end;
stop_profiling(migration, [_Node|_]) ->
    devo_trace:stop_trace();
stop_profiling(rq_migration, [Node|_]) ->
    Res=rpc:call(Node, devo_sampling, stop,[]),
    case Res of 
        {badrpc, Reason} ->
            io:format("Devo failed to stop profiling for reason:\n~p\n",
                      [Reason]);
        _ -> 
            Res
    end,
    erlang:start_timer(1, self(), stop_profile),
    devo_trace:stop_trace();
stop_profiling(inter_node, _Nodes) ->
    erlang:start_timer(1, self(), stop_profile),
    devo_trace:stop_trace();
stop_profiling(s_group, _Nodes) ->
    devo_trace:stop_trace();
stop_profiling(undefined,_) ->
    ok;
stop_profiling(Cmd, _Nodes) ->
    io:format("stop_profiling: unnexpected command:~p\n", [Cmd]),
    ok. 
