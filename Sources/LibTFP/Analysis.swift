// Copyright 2019 Google LLC
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     https://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

import SIL

public typealias StructDecl = [(name: String, type: Type)]

public typealias Environment = [String: FunctionSummary]
public typealias TypeEnvironment = [String: StructDecl]

public class Analyzer {
  public var warnings: [String: [Warning]] = [:]
  public var environment: Environment = [:]
  public var typeEnvironment: TypeEnvironment = [:]

  public init() {}

  let supportedStructDecls: Set = [
    "pattern_binding_decl", "var_decl",
    "constructor_decl", "destructor_decl", "func_decl",
    // TODO(#19): struct/class/enum decl?
  ]
  public func analyze(_ ast: SExpr) {
    guard case let .record("source_file", decls) = ast else {
      // TODO: Warn
      return
    }
    structLoop: for structDecl in decls {
      guard case let .value(.record("struct_decl", structDeclBody)) = structDecl,
                     structDeclBody.count > 2,
            case     .field("range", .sourceRange(_))     = structDeclBody[0],
            case let .value(.string(structName)) = structDeclBody[1] else { continue }
      var fields: StructDecl = []
      for decl in structDeclBody.suffix(from: 2) {
        // Ignore everything that's not a nested record...
        guard case let .value(.record(declName, declBody)) = decl else { continue }
        // but once a record is found, make sure we understand what it means.
        guard          supportedStructDecls.contains(declName) else { continue structLoop }
        // Finally, try to see if it declares a new field.
        guard          declName == "var_decl",
                       declBody.count >= 3,
              case     .field("range", .sourceRange(_))   = declBody[0],
              case let .value(.string(fieldName))         = declBody[1],
              case let .field("type", .string(fieldTypeName)) = declBody[2],
                       declBody.contains(.field("readImpl", .symbol("stored"))),
                   let fieldType = try? Type.parse(fromString: "$" + fieldTypeName) else { continue }
        fields.append((fieldName, fieldType))
      }
      typeEnvironment[structName] = fields
    }
  }

  public func analyze(_ module: Module) {
    for f in module.functions {
      analyze(f)
    }
  }

  func analyze(_ function: Function) {
    warnings[function.name] = captureWarnings {
      environment[function.name] = abstract(function, inside: typeEnvironment)
    }
  }

}

////////////////////////////////////////////////////////////////////////////////
// MARK: - Instantiation of constraints for the call chain

public func instantiate(constraintsOf name: String,
                        inside env: Environment) -> [Constraint] {
  let instantiator = ConstraintInstantiator(name, env)
  return instantiator.constraints
}

class ConstraintInstantiator {
  let environment: Environment
  var constraints: [Constraint] = []
  var callStack = Set<String>() // To sure we don't recurse
  let freshVar = makeVariableGenerator()

  init(_ name: String,
       _ env: Environment) {
    self.environment = env
    guard let summary = environment[name] else { return }
    let subst = makeSubstitution()
    let _ = apply(name,
                  to: summary.argExprs.map{ $0.map{ substitute($0, using: subst) }},
                  at: .top,
                  assuming: .true)
  }

  func makeSubstitution() -> (Var) -> Expr {
    var varMap = DefaultDict<Var, Var>(withDefault: freshVar)
    return { varMap[$0].expr }
  }

  func apply(_ name: String, to args: [Expr?], at stack: CallStack, assuming applyCond: BoolExpr) -> Expr? {
    guard let summary = environment[name] else { return nil }

    guard !callStack.contains(name) else { return nil }
    callStack.insert(name)
    defer { callStack.remove(name) }

    // Instantiate the constraint system for the callee.
    let subst = makeSubstitution()

    assert(summary.argExprs.count == args.count)
    for (maybeFormal, maybeActual) in zip(summary.argExprs, args) {
      // NB: Only instantiate the mapping for args that have some constraints
      //     associated with them.
      guard let formal = maybeFormal else { continue }
      guard let actual = maybeActual else { continue }
      constraints += (substitute(formal, using: subst) ≡ actual).map{ .expr($0, assuming: applyCond, .implied, stack) }
    }

    // Replace the variables in the body of the summary with fresh ones to avoid conflicts.
    for constraint in summary.constraints {
      switch constraint {
      case let .expr(expr, assuming: cond, origin, loc):
        constraints.append(.expr(substitute(expr, using: subst),
                                 assuming: applyCond && substitute(cond, using: subst),
                                 origin,
                                 .frame(loc, caller: stack)))
      case let .call(name, args, maybeResult, assuming: cond, loc):
        let fullCond = applyCond && substitute(cond, using: subst)
        let newStack = CallStack.frame(loc, caller: stack)
        let maybeApplyResult = apply(name, to: args.map{ $0.map{substitute($0, using: subst)} },
                                           at: newStack,
                                           assuming: fullCond)
        if let applyResult = maybeApplyResult,
           let result = maybeResult {
          constraints += (substitute(result, using: subst) ≡ applyResult).map{ .expr($0, assuming: fullCond, .implied, newStack) }
        }
      }
    }

    guard let result = summary.retExpr else { return nil }
    return substitute(result, using: subst)
  }
}

func warnAboutUnresolvedAsserts(_ constraints: [Constraint]) {
  var varUses: [Var: Int] = [:]
  for constraint in constraints {
    let _ = substitute(constraint, using: { varUses[$0, default: 0] += 1; return nil })
  }

  var seenLocations = Set<SourceLocation>()
  for constraint in constraints {
    if case let .expr(.var(v), assuming: _, .asserted, stack) = constraint,
       varUses[.bool(v)] == 1,
       case let .frame(maybeLocation, caller: _) = stack,
       let location = maybeLocation,
       !seenLocations.contains(location) {
      warn("Failed to parse the assert condition", location)
      seenLocations.insert(location)
    }
  }
}

////////////////////////////////////////////////////////////////////////////////
// MARK: - CustomStringConvertible instances

extension FunctionSummary: CustomStringConvertible {
  fileprivate var signature: String {
    "(" + argExprs.map{ $0?.description ?? "*" }.joined(separator: ", ") + ") -> " + (retExpr?.description ?? "*")
  }
  public var description: String {
    guard !constraints.isEmpty else { return signature }
    return constraints.description + " => " + signature
  }
  public var prettyDescription: String {
    guard constraints.count > 4 else { return description }
    return "[" + constraints.map{ $0.description }.joined(separator: ",\n ") + "] => " + signature
  }
}
