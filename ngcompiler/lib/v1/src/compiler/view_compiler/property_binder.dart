import 'package:ngcompiler/v1/src/compiler/expression_parser/ast.dart' as ast;
import 'package:ngcompiler/v1/src/compiler/identifiers.dart';
import 'package:ngcompiler/v1/src/compiler/ir/model.dart' as ir;
import 'package:ngcompiler/v1/src/compiler/output/output_ast.dart' as o;
import 'package:ngcompiler/v1/src/compiler/view_compiler/view_compiler_utils.dart';

import 'bound_value_converter.dart';
import 'compile_element.dart' show CompileElement, CompileNode;
import 'compile_method.dart' show CompileMethod;
import 'compile_view.dart' show CompileView, NodeReference;
import 'constants.dart' show DetectChangesVars;
import 'interpolation_utils.dart';
import 'ir/view_storage.dart';
import 'update_statement_visitor.dart' show bindingToUpdateStatements;
import 'view_name_resolver.dart';

/// For each binding, creates code to update the binding.
///
/// Example:
///     final currVal_1 = this.context.someBoolValue;
///     if (import6.checkBinding(this._expr_1,currVal_1)) {
///       this.renderer.setElementClass(this._el_4,'disabled',currVal_1);
///       this._expr_1 = currVal_1;
///     }
void bindAndWriteToRenderer(
  List<ir.Binding> bindings,
  BoundValueConverter converter,
  o.Expression? appViewInstance,
  NodeReference? renderNode,
  bool isHtmlElement,
  ViewNameResolver nameResolver,
  ViewStorage storage,
  CompileMethod targetMethod, {
  bool isHostComponent = false,
  bool calcChanged = false,
}) {
  final dynamicMethod = CompileMethod();
  final constantMethod = CompileMethod();
  for (var binding in bindings) {
    if (binding.isDirect) {
      _directBinding(
        binding,
        converter,
        binding.source.isImmutable ? constantMethod : dynamicMethod,
        appViewInstance,
        renderNode,
        isHtmlElement,
      );
      continue;
    }
    _checkBinding(
        binding,
        converter,
        nameResolver,
        appViewInstance,
        renderNode,
        isHtmlElement,
        calcChanged,
        storage,
        dynamicMethod,
        constantMethod,
        isHostComponent);
  }
  if (constantMethod.isNotEmpty) {
    targetMethod.addStmtsIfFirstCheck(constantMethod.finish());
  }
  if (dynamicMethod.isNotEmpty) {
    targetMethod.addStmts(dynamicMethod.finish());
  }
}

void bindRenderText(
    ir.Binding binding, CompileNode compileNode, CompileView? view) {
  if (binding.source.isImmutable) {
    // We already set the value to the text node at creation
    return;
  }
  _directBinding(
    binding,
    BoundValueConverter.forView(view!),
    view.detectChangesRenderPropertiesMethod,
    o.THIS_EXPR,
    compileNode.renderNode,
    false,
  );
}

void bindRenderInputs(
    List<ir.Binding> bindings, CompileElement compileElement) {
  var appViewInstance = compileElement.component == null
      ? o.THIS_EXPR
      : compileElement.componentView;
  var renderNode = compileElement.renderNode;
  var view = compileElement.view!;
  var converter = BoundValueConverter.forView(view);
  bindAndWriteToRenderer(
    bindings,
    converter,
    appViewInstance,
    renderNode,
    compileElement.isHtmlElement,
    view.nameResolver,
    view.storage,
    view.detectChangesRenderPropertiesMethod,
  );
}

void bindDirectiveInputs(
  List<ir.Binding> inputs,
  ir.MatchedDirective directive,
  CompileElement? compileElement, {
  bool isHostComponent = false,
}) {
  if (!directive.hasInputs) return;
  var view = compileElement!.view!;
  var detectChangesInInputsMethod = view.detectChangesInInputsMethod;
  var afterChanges = directive.hasLifecycle(ir.Lifecycle.afterChanges);
  var isOnPushComp = directive.isComponent && directive.isOnPush;
  var calcChanged = isOnPushComp || afterChanges;

  // We want to call AfterChanges lifecycle only if we detect a change.
  // Therefore we keep track of changes using bool changed variable.
  // At the beginning of change detecting inputs we reset this flag to false,
  // and then set it to true if any of it's inputs change.
  if (calcChanged && !isHostComponent) {
    detectChangesInInputsMethod
        .addStmt(DetectChangesVars.changed.set(o.literal(false)).toStmt());
  }
  bindAndWriteToRenderer(
    inputs,
    BoundValueConverter.forView(view),
    directive.providerSource!.build(),
    null,
    false,
    view.nameResolver,
    view.storage,
    detectChangesInInputsMethod,
    isHostComponent: isHostComponent,
    calcChanged: calcChanged,
  );
  if (isOnPushComp) {
    detectChangesInInputsMethod.addStmt(o.IfStmt(DetectChangesVars.changed, [
      compileElement.componentView!.callMethod('markAsCheckOnce', []).toStmt()
    ]));
  }
}

void _directBinding(
  ir.Binding binding,
  BoundValueConverter converter,
  CompileMethod method,
  o.Expression? appViewInstance,
  NodeReference? renderNode,
  bool isHtmlElement,
) {
  var expression =
      converter.convertSourceToExpression(binding.source, binding.target.type)!;
  var updateStatements = bindingToUpdateStatements(
    binding,
    appViewInstance,
    renderNode,
    isHtmlElement,
    expression,
  );
  method.addStmts(updateStatements);
}

/// For the given binding, creates code to update the binding.
///
/// Example:
///     final currVal_1 = this.context.someBoolValue;
///     if (import6.checkBinding(this._expr_1,currVal_1)) {
///       this.renderer.setElementClass(this._el_4,'disabled',currVal_1);
///       this._expr_1 = currVal_1;
///     }
void _checkBinding(
    ir.Binding binding,
    BoundValueConverter converter,
    ViewNameResolver nameResolver,
    o.Expression? appViewInstance,
    NodeReference? renderNode,
    bool isHtmlElement,
    bool calcChanged,
    ViewStorage storage,
    CompileMethod dynamicMethod,
    CompileMethod constantMethod,
    bool isHostComponent) {
  // Add to view bindings collection.
  var bindingIndex = nameResolver.createUniqueBindIndex();

  // Expression that points to _expr_## stored value.
  var fieldExpr = _createBindFieldExpr(bindingIndex);

  // Expression for current value of expression when value is re-read.
  var currValExpr = _createCurrValueExpr(bindingIndex);

  var updatedExpr = _maybeOptimizeInterpolation(
      binding.source, currValExpr, converter, binding.target.type)!;

  var updateStmts = bindingToUpdateStatements(
    binding,
    appViewInstance,
    renderNode,
    isHtmlElement,
    updatedExpr,
  );

  if (calcChanged) {
    updateStmts.add(DetectChangesVars.changed.set(o.literal(true)).toStmt());
  }

  final checkExpression =
      converter.convertSourceToExpression(binding.source, binding.target.type);

  final checkBindingExpr = _checkBindingExpr(binding, fieldExpr, currValExpr);
  _bind(
    storage,
    currValExpr,
    fieldExpr,
    checkExpression,
    checkBindingExpr,
    binding.source.isImmutable,
    binding.source.isNullable,
    updateStmts,
    dynamicMethod,
    constantMethod,
    fieldType: binding.target.type,
    isHostComponent: isHostComponent,
  );
}

o.Expression _checkBindingExpr(ir.Binding binding,
    o.ReadClassMemberExpr fieldExpr, o.ReadVarExpr currValExpr) {
  return binding.source.accept(_CheckBindingVisitor(fieldExpr, currValExpr));
}

class _CheckBindingVisitor
    implements ir.BindingSourceVisitor<o.Expression, void> {
  final o.ReadClassMemberExpr fieldExpr;
  final o.ReadVarExpr currValExpr;

  _CheckBindingVisitor(this.fieldExpr, this.currValExpr);

  @override
  o.Expression visitBoundExpression(
    ir.BoundExpression boundExpression, [
    void _,
  ]) {
    return o.importExpr(Runtime.checkBinding).callFn([
      fieldExpr,
      currValExpr,
      o.literal(boundExpression.expression.source),
      o.literal(boundExpression.expression.location),
    ]);
  }

  @override
  o.Expression visitBoundI18nMessage(
    ir.BoundI18nMessage boundI18nMessage, [
    void _,
  ]) {
    return o.importExpr(Runtime.checkBinding).callFn([fieldExpr, currValExpr]);
  }

  @override
  o.Expression visitComplexEventHandler(
    ir.ComplexEventHandler complexEventHandler, [
    void _,
  ]) {
    throw UnsupportedError('Event handlers are not change detected');
  }

  @override
  o.Expression visitSimpleEventHandler(
    ir.SimpleEventHandler simpleEventHandler, [
    void _,
  ]) {
    throw UnsupportedError('Event handlers are not change detected');
  }

  @override
  o.Expression visitStringLiteral(
    ir.StringLiteral stringLiteral, [
    void _,
  ]) {
    return o.importExpr(Runtime.checkBinding).callFn([fieldExpr, currValExpr]);
  }
}

o.ReadClassMemberExpr _createBindFieldExpr(num exprIndex) =>
    o.ReadClassMemberExpr('_expr_$exprIndex');

o.ReadVarExpr _createCurrValueExpr(num exprIndex) =>
    o.variable('currVal_$exprIndex');

/// Generates code to bind template expression.
///
/// If [checkExpression] is immutable, code is added to [literalMethod] to be
/// executed once when the component is created. Otherwise statements are added
/// to [method] to be executed on each change detection cycle.
void _bind(
  ViewStorage storage,
  o.ReadVarExpr currValExpr,
  o.ReadClassMemberExpr fieldExpr,
  o.Expression? checkExpression,
  o.Expression checkBindingExpr,
  bool isImmutable,
  bool isNullable,
  List<o.Statement> actions,
  CompileMethod method,
  CompileMethod literalMethod, {
  o.OutputType? fieldType,
  bool isHostComponent = false,
}) {
  if (isImmutable) {
    // If the expression is immutable, it will never change, so we can run it
    // once on the first change detection.
    if (!isHostComponent) {
      _bindLiteral(checkExpression!, actions, currValExpr.name!, fieldExpr.name,
          literalMethod, isNullable);
    }
    return;
  }
  if (checkExpression == null) {
    // e.g. an empty expression was given
    return;
  }
  var previousValueField = storage.allocate(
    fieldExpr.name,
    modifiers: const [o.StmtModifier.Private],
    outputType: o.OBJECT_TYPE.asNullable(),
  );
  method
    ..addStmt(
      currValExpr.set(checkExpression).toDeclStmt(null, [o.StmtModifier.Final]),
    )
    ..addStmt(
      o.IfStmt(
        checkBindingExpr,
        [
          ...actions,
          storage.buildWriteExpr(previousValueField, currValExpr).toStmt()
        ],
      ),
    );
}

/// The same as [_bind], but we know that [checkExpression] is a literal.
///
/// This means we don't need to create a change detection field or check if it
/// has changed. We know for sure that there will only be one transition from
/// [null] to whatever the value of [checkExpression] is. So we can just output
/// the [actions] and run them once on the first change detection run.
// TODO(alorenzen): Replace usages with _directBinding().
void _bindLiteral(
    o.Expression checkExpression,
    List<o.Statement> actions,
    String currValName,
    String fieldName,
    CompileMethod method,
    bool isNullable) {
  if (checkExpression == o.NULL_EXPR ||
      (checkExpression is o.LiteralExpr && checkExpression.value == null)) {
    // In this case, there is no transition, since change detection variables
    // are initialized to null.
    return;
  }

  var mappedActions = actions
      // Replace all 'currVal_X' with the actual expression
      .map(
          (stmt) => o.replaceVarInStatement(currValName, checkExpression, stmt))
      // Replace all 'expr_X' with 'null'
      .map((stmt) => o.replaceVarInStatement(fieldName, o.NULL_EXPR, stmt));
  if (isNullable) {
    method.addStmt(
      o.IfStmt(checkExpression.notEquals(o.NULL_EXPR), mappedActions.toList()),
    );
  } else {
    method.addStmts(mappedActions.toList());
  }
}

// Component or directive level host properties are change detected inside
// the component itself inside detectHostChanges method, no need to
// generate code at call-site.
void bindDirectiveHostProps(
  ir.MatchedDirective directive,
  CompileElement compileElement,
) {
  if (!directive.hasHostProperties) {
    return;
  }
  o.Expression detectHostChanges;
  if (directive.isComponent) {
    detectHostChanges = compileElement.componentView!.callMethod(
      'detectHostChanges',
      [DetectChangesVars.firstCheck],
    );
  } else {
    final directiveInstance =
        unwrapDirectiveInstance(directive.providerSource!.build());
    // For @Component-annotated classes that extend @Directive classes, i.e.:
    //
    // @Directive(...)
    // class D {
    //   @HostBinding()
    //   ...
    // }
    //
    // @Component(...)
    // class C extends D {}
    //
    // In this case, `directiveInstance` is `Instance of C`, which in case will
    // not have a  `detectHostChanges()` (if it did, it would have returned true
    // for `.directive.isComponent` above).
    if (directiveInstance == null) {
      return;
    }
    detectHostChanges = directiveInstance.callMethod(
      'detectHostChanges',
      [
        compileElement.component != null
            ? compileElement.componentView!
            : o.THIS_EXPR,
        compileElement.renderNode.toReadExpr(),
      ],
    );
  }
  compileElement.view!.detectChangesRenderPropertiesMethod.addStmt(
    detectHostChanges.toStmt(),
  );
}

bool isPrimitiveTypeName(String typeName) {
  switch (typeName) {
    case 'bool':
    case 'int':
    case 'num':
    case 'double':
    case 'String':
      return true;
  }
  return false;
}

// Returns whether [source] is an interpolation that can be optimized.
//
// When true, the [source] should be change detected directly, rather than
// change detecting the result of the interpolation.
bool _shouldInterpolateAfterCheck(ir.BindingSource source) =>
    isInterpolation(source) &&
    (source.isBool || source.isNumber || source.isDouble || source.isInt) &&
    !source.isImmutable;

// Bindings that interpolate a single expression of a primitive type are
// optimized by change detecting the expression directly rather than the
// interpolated expression. The expression is then interpolated only when the
// binding is updated.
// The reason to exclude immutable binding source is because [bindLiteral]
// method would replace current variable to checkExpression. It results in
// binding interpolate method twice.
o.Expression? _maybeOptimizeInterpolation(
    ir.BindingSource source,
    o.ReadVarExpr currValExpr,
    BoundValueConverter converter,
    o.OutputType? type) {
  if (!_shouldInterpolateAfterCheck(source)) {
    return currValExpr;
  }
  final oldSource = source as ir.BoundExpression;
  final oldInterpolation = oldSource.expression.ast as ast.Interpolation;
  final interpolationSource = oldSource.withNewExpression(ast.Interpolation(
      oldInterpolation.strings, [ast.VariableRead(currValExpr.name!)]));
  return converter.convertSourceToExpression(interpolationSource, type);
}
