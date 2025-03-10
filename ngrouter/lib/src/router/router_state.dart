import 'package:collection/collection.dart';
import 'package:ngdart/angular.dart' show ComponentFactory, ComponentRef;

import '../route_definition.dart';
import '../route_path.dart';
import '../url.dart';

/// Represents the state of the router, which is a URL and matching [routes].
class RouterState extends Url {
  /// Matching route definitions at this URL.
  final List<RouteDefinition> routes;

  /// A map of URL parameters.
  ///
  /// If matched RouteDefinition has a path '/customer/:id' and the URL is
  /// '/customer/5', parameters would equal { 'id': '5' }.
  final Map<String, String> parameters;

  /// Whether this state was caused by a `popstate` event.
  final bool fromPopState;

  late final routePath = RoutePath.fromRoutes(routes);

  RouterState(
    String path,
    List<RouteDefinition>? routes, {
    Map<String, String>? parameters,
    String fragment = '',
    Map<String, String>? queryParameters,
    this.fromPopState = false,
  })  : parameters = Map.unmodifiable(parameters ?? {}),
        routes = List.unmodifiable(routes ?? []),
        super(path, queryParameters: queryParameters, fragment: fragment);

  @override
  String toString() => '#$RouterState {${super.toString()}}';
}

/// **Internal only**: An easily mutable version of [RouterState].
///
/// MutableRouterState enables the Router to set and unset values to build up
/// a RouterState. In addition to the normal RouterState properties, it also
/// maintains a list of outlets and components that will be attached. These
/// are [QueueList]s so that elements can be added in the front or back.
class MutableRouterState {
  final List<ComponentRef<Object>> components = [];
  final Map<ComponentRef<Object>, ComponentFactory<Object>> factories = {};
  final List<Map<String, String>> _parameterStack = [];
  final List<RouteDefinition> routes = [];

  String fragment = '';
  String path = '';
  Map<String, String> queryParameters = {};
  bool fromPopState = false;

  Map<String, String> get parameters {
    var result = <String, String>{};
    for (var p in _parameterStack) {
      result.addAll(p);
    }
    return result;
  }

  RouterState build() {
    return RouterState(path, routes.toList(),
        fragment: fragment,
        queryParameters: queryParameters,
        parameters: parameters,
        fromPopState: fromPopState);
  }

  /// Pushes a [route] and its [match].
  void push(RouteDefinition route, Match match) {
    routes.add(route);
    _parameterStack.add(_parameters(route, match));
  }

  /// Pops the last pushed [RouteDefinition] and its [Match].
  void pop() {
    routes.removeLast();
    _parameterStack.removeLast();
  }

  /// Returns [route] [parameters] from [match], mapped from name to value.
  Map<String, String> _parameters(RouteDefinition route, Match match) {
    var result = <String, String>{};
    var index = 1;
    for (var parameter in route.parameters) {
      result[parameter] = Uri.decodeComponent(match[index++]!);
    }
    return result;
  }
}
