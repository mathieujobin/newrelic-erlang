-module(newrelic_statman).
-compile([export_all]).

poll() ->
    {ok, Metrics} = statman_aggregator:get_window(60),
    Histograms = lists:filter(
                   fun (Metric) ->
                           proplists:get_value(type, Metric) =:= histogram andalso
                               (not is_list(proplists:get_value(node, Metric))) andalso
                               proplists:get_value(value, Metric) =/= []
                   end,
                   Metrics),

    Ms = lists:filter(
           fun (M) -> M =/= [] end,
           lists:foldl(fun (M, Acc) ->
                               transform_histogram(M) ++ Acc
                       end, [], Histograms)),

    Counters = lists:filter(
                   fun (Metric) ->
                           proplists:get_value(type, Metric) =:= counter andalso
                               (not is_list(proplists:get_value(node, Metric)))
                   end,
                   Metrics),

    Errs = lists:flatmap(
               fun (Metric) ->
                       transform_counter(Metric)
               end,
               Counters),

    {[webtransaction_total(Ms), db_total(Ms), errors_total(Errs) | Ms], Errs}.


transform_counter(Metric) ->
    case proplists:get_value(key, Metric) of
        {Scope, {error, {Type, Message}}} when is_binary(Scope) ->
            {MegaSecs, Secs, MicroSecs} = os:timestamp(),
            Error = [MegaSecs * 1000000 + Secs + MicroSecs / 1000000,
                     scope2bin(Scope),
                     to_bin(Message),
                     to_bin(Type),
                     {[{<<"parameter_groups">>,{[]}},
                        {<<"stack_trace">>, []},
                        {<<"request_params">>, {[]}},
                        {<<"request_uri">>, Scope}
                      ]}],
            lists:duplicate(proplists:get_value(value, Metric), Error);

        _ ->
            []
    end.


transform_histogram(Metric) ->
    Summary = statman_histogram:summary(proplists:get_value(value, Metric)),
    Data = [proplists:get_value(observations, Summary),
            proplists:get_value(sum, Summary) / 1000000,
            proplists:get_value(sum, Summary) / 1000000,
            proplists:get_value(min, Summary) / 1000000,
            proplists:get_value(max, Summary) / 1000000,
            proplists:get_value(sum2, Summary) / 1000000000
           ],

    case proplists:get_value(key, Metric) of
        {Scope, {db, Segment}} when is_binary(Scope) ->
            [
             [{[{name, <<"Database", "/", (to_bin(Segment))/binary>>},
                {scope, scope2bin(Scope)}]},
              Data],

             [{[{name, <<"Database/allWeb">>},
                {scope, <<"">>}]},
              Data],

             [{[{name, <<"Database/all">>},
                {scope, <<"">>}]},
              Data]

            ];

        {Scope, {ext, Host}} when is_binary(Scope) andalso is_binary(Host) ->
            [
             [{[{name, <<"External/all">>},
               {scope, <<"">>}]},
             Data],

             [{[{name, <<"External/allWeb">>},
               {scope, <<"">>}]},
             Data],

             [{[{name, <<"External/", Host/binary>>},
               {scope, <<"">>}]},
             Data],

             [{[{name, <<"External/", Host/binary, "/all">>},
               {scope, <<"">>}]},
             Data],

             [{[{name, <<"External/", Host/binary>>},
               {scope, scope2bin(Scope)}]},
              Data]

            ];

        {{background, Scope}, total} when is_binary(Scope) ->
            [[{[{name, bgscope2bin(Scope)},
                {scope, <<"">>}]},
              Data]];

        {{background, Scope}, Segment} when is_binary(Scope) ->
            [[{[{name, to_bin(Segment)},
                {scope, bgscope2bin(Scope)}]},
             Data]];

        {Scope, {Class, Segment}} when is_binary(Scope) ->
            [[{[{name, <<(class2bin(Class))/binary, "/", (to_bin(Segment))/binary>>},
                {scope, scope2bin(Scope)}]},
              Data]];

        {Scope, total} when is_binary(Scope) ->
            [[{[{name, <<"WebTransaction/Uri", Scope/binary>>},
                {scope, <<"">>}]},
             Data]];

        {A, B} when is_atom(A) andalso is_atom(B) ->
            [[{[{name, <<"OtherTransaction/",
                         (to_bin(A))/binary, "/",
                         (to_bin(B))/binary>>},
                {scope, <<"">>}]},
             Data]];
        _ ->
            []
    end.


webtransaction_total(Ms) ->
    Name = <<"WebTransaction">>,
    N    = lists:sum(pluck(Name, 1, Ms)),
    Sum  = lists:sum(pluck(Name, 2, Ms)),
    Min  = lists:min(pluck(Name, 4, Ms)),
    Max  = lists:max(pluck(Name, 5, Ms)),
    Sum2 = lists:sum(pluck(Name, 6, Ms)),

    [{[{name, <<"HttpDispatcher">>},
       {scope, <<"">>}]},
     [N, Sum, Sum, Min, Max, Sum2]].


db_total(Ms) ->
    Name = <<"Database">>,
    N    = lists:sum(pluck(Name, 1, Ms)),
    Sum  = lists:sum(pluck(Name, 2, Ms)),
    Min  = lists:min(pluck(Name, 4, Ms)),
    Max  = lists:max(pluck(Name, 5, Ms)),
    Sum2 = lists:sum(pluck(Name, 6, Ms)),

    [{[{name, <<"Database/all">>},
       {scope, <<"">>}]},
     [N, Sum, Sum, Min, Max, Sum2]].


errors_total(Errors) ->
    [{[{name, <<"Errors/all">>},
       {scope, <<"">>}]},
     [length(Errors), 0.0, 0.0, 0.0, 0.0, 0.0]].


pluck(_, _, []) ->
    [0];
pluck(Name, N, L) ->
    lists:map(fun ([_, []]) -> 0;
                  ([{Struct}, D]) ->
                      case binary:match(proplists:get_value(name, Struct), Name) of
                          nomatch ->
                              0;
                          _ ->
                              case proplists:get_value(scope, Struct) =:= <<"">> of
                                  true ->
                                      lists:nth(N, D);
                                  false ->
                                      0
                              end
                      end
              end, L).



class2bin(db) -> <<"Database">>;
class2bin(Atom) when is_atom(Atom) ->
    [F | R] = atom_to_list(Atom),
    list_to_binary([string:to_upper(F) | R]).

to_bin(Atom) when is_atom(Atom) -> list_to_binary(atom_to_list(Atom));
to_bin(Bin) when is_binary(Bin)-> Bin.

bgscope2bin(Scope) ->
    <<"OtherTransaction/Python/", Scope/binary>>.

scope2bin(Url) when is_binary(Url) ->
    <<"WebTransaction/Uri", Url/binary>>.
