//===----------------------------------------------------------------------===//
//
// This source file is part of the Soto for AWS open source project
//
// Copyright (c) 2017-2022 the Soto project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.txt for the list of Soto project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

import Foundation
import SotoSmithy
import SotoSmithyAWS

extension AwsService {
    /// Generate context for outputting Shapes
    func generateShapesContext() throws -> [String: Any] {
        var context: [String: Any] = [:]
        context["name"] = serviceName

        markInputOutputShapes(model)

        // generate enums
        let traitEnums: [EnumContext] = try model
            .select(from: "[trait|enum]")
            .compactMap { self.generateEnumTraitContext($0.value, shapeName: $0.key.shapeName) }
        let shapeEnums: [EnumContext] = model
            .select(type: EnumShape.self)
            .compactMap { self.generateEnumContext($0.value, shapeName: $0.key.shapeName) }
        let enums = (traitEnums + shapeEnums).sorted { $0.name < $1.name }
        var shapeContexts: [[String: Any]] = enums.map { ["enum": $0] }

        // generate structures
        let structures = model.select(type: StructureShape.self).sorted { $0.key.shapeName < $1.key.shapeName }
        for structure in structures {
            guard let shapeContext = self.generateStructureContext(structure.value, shapeId: structure.key, typeIsUnion: false) else { continue }
            shapeContexts.append(["struct": shapeContext])
        }

        // generate unions
        let unions = model.select(type: UnionShape.self).sorted { $0.key.shapeName < $1.key.shapeName }
        for union in unions {
            // if union has one member then treat type as struct
            let typeIsUnion = union.value.members?.count == 1 ? false : true
            guard let shapeContext = self.generateStructureContext(union.value, shapeId: union.key, typeIsUnion: typeIsUnion) else { continue }
            if typeIsUnion {
                shapeContexts.append(["enumWithValues": shapeContext])
            } else {
                shapeContexts.append(["struct": shapeContext])
            }
        }

        if shapeContexts.count > 0 {
            context["shapes"] = shapeContexts
        }
        return context
    }

    /// Generate the context information for outputting an enum from strings with enum traits
    func generateEnumTraitContext(_ shape: Shape, shapeName: String) -> EnumContext? {
        guard let trait = shape.trait(type: EnumTrait.self) else { return nil }
        let usedInInput = shape.hasTrait(type: SotoInputShapeTrait.self)
        let usedInOutput = shape.hasTrait(type: SotoOutputShapeTrait.self)
        guard usedInInput || usedInOutput else { return nil }

        // Operations
        var valueContexts: [EnumMemberContext] = []
        let enumDefinitions = trait.value.sorted { $0.value < $1.value }
        for value in enumDefinitions {
            var key = value.value.toSwiftEnumCase()
            if key.allLetterIsNumeric() {
                key = "\(shapeName.toSwiftVariableCase())\(key)"
            }
            valueContexts.append(EnumMemberContext(case: key, documentation: processDocs(value.documentation), string: value.value))
        }
        return EnumContext(
            name: shapeName.toSwiftClassCase(),
            documentation: processDocs(from: shape),
            values: valueContexts,
            isExtensible: shape.hasTrait(type: SotoExtensibleEnumTrait.self)
        )
    }

    /// Generate the context information for outputting an enum from strings with enum traits
    func generateEnumContext(_ enumShape: EnumShape, shapeName: String) -> EnumContext? {
        let usedInInput = enumShape.hasTrait(type: SotoInputShapeTrait.self)
        let usedInOutput = enumShape.hasTrait(type: SotoOutputShapeTrait.self)
        guard usedInInput || usedInOutput else { return nil }
        guard let members = enumShape.members else { return nil }
        // Operations
        let valueContexts: [EnumMemberContext] = members.enumerated().map { enumerated -> EnumMemberContext in
            var key = enumerated.element.key.toSwiftEnumCase()
            if key.allLetterIsNumeric() {
                key = "\(shapeName.toSwiftVariableCase())\(key)"
            }
            let value: String
            if let enumValueTrait = enumerated.element.value.trait(type: EnumValueTrait.self) {
                switch enumValueTrait.value {
                case .string(let name):
                    value = name
                case .integer(let integer):
                    value = integer.description
                    fatalError("intEnum is currently not supported")
                }
            } else {
                value = enumerated.element.key
            }
            let documentation = enumerated.element.value.trait(type: DocumentationTrait.self)
            return EnumMemberContext(
                case: key,
                documentation: documentation.map { processDocs($0.value) } ?? [],
                string: value
            )
        }
        return EnumContext(
            name: shapeName.toSwiftClassCase(),
            documentation: processDocs(from: enumShape),
            values: valueContexts.sorted { $0.case < $1.case },
            isExtensible: enumShape.hasTrait(type: SotoExtensibleEnumTrait.self)
        )
    }

    /// Generate the context information for outputting a shape
    func generateStructureContext(_ shape: CollectionShape, shapeId: ShapeId, typeIsUnion: Bool) -> StructureContext? {
        let shapeName = shapeId.shapeName
        var shapeOptions: [String] = []
        var xmlNamespace: String?
        let payloadMember = getPayloadMember(from: shape)

        guard let shapeProtocol = getShapeProtocol(shape, hasPayload: payloadMember != nil) else { return nil }

        let contexts = self.generateMembersContexts(shape, shapeName: shapeName, typeIsUnion: typeIsUnion)

        // get payload options
        let operationShape = shape.trait(type: SotoRequestShapeTrait.self)?.operationShape
        if operationShape?.hasTrait(type: AwsHttpChecksumTrait.self) == true {
            shapeOptions.append("checksumHeader")
        }
        if operationShape?.hasTrait(type: HttpChecksumRequiredTrait.self) == true ||
            operationShape?.trait(type: AwsHttpChecksumTrait.self)?.requestChecksumRequired == true
        {
            shapeOptions.append("checksumRequired")
        }
        // search for content-md5 header
        if let members = shape.members {
            for member in members.values {
                if let headerTrait = member.trait(type: HttpHeaderTrait.self) {
                    if headerTrait.value.lowercased() == "content-md5" {
                        shapeOptions.append("md5ChecksumHeader")
                    }
                }
            }
        }
        // check streaming traits
        if let payloadMember = payloadMember, let payload = model.shape(for: payloadMember.value.target) {
            if payload is BlobShape {
                shapeOptions.append("rawPayload")
                if payload.hasTrait(type: StreamingTrait.self) {
                    shapeOptions.append("allowStreaming")
                    if !payload.hasTrait(type: RequiresLengthTrait.self),
                       let operationShape = operationShape,
                       operationShape.hasTrait(type: AwsAuthUnsignedPayloadTrait.self)
                    {
                        shapeOptions.append("allowChunkedStreaming")
                    }
                }
            }
        }
        if serviceProtocolTrait is AwsProtocolsRestXmlTrait {
            xmlNamespace = shape.trait(type: XmlNamespaceTrait.self)?.uri
        }
        let recursive = doesShapeHaveRecursiveOwnReference(shape, shapeId: shapeId)
        let initParameters = contexts.members.compactMap {
            !$0.deprecated ? InitParamContext(parameter: $0.parameter, type: $0.type, default: $0.default) : nil
        }
        let object: String
        if typeIsUnion {
            object = recursive ? "indirect enum" : "enum"
        } else {
            object = recursive ? "final class" : "struct"
        }
        return StructureContext(
            object: object,
            name: shapeName.toSwiftClassCase(),
            shapeProtocol: shapeProtocol,
            payload: payloadMember?.key.toSwiftLabelCase(),
            options: shapeOptions.count > 0 ? shapeOptions.map { ".\($0)" }.joined(separator: ", ") : nil,
            namespace: xmlNamespace,
            isEncodable: shape.hasTrait(type: SotoInputShapeTrait.self),
            isDecodable: shape.hasTrait(type: SotoOutputShapeTrait.self),
            encoding: contexts.encoding,
            members: contexts.members,
            initParameters: initParameters,
            awsShapeMembers: contexts.awsShapeMembers,
            codingKeys: contexts.codingKeys,
            validation: contexts.validation,
            requiresDefaultValidation: contexts.validation.count != contexts.members.count,
            deprecatedMembers: contexts.members.compactMap { $0.deprecated ? $0.parameter : nil }
        )
    }

    struct MembersContexts {
        var members: [MemberContext] = []
        var awsShapeMembers: [MemberEncodingContext] = []
        var codingKeys: [CodingKeysContext] = []
        var validation: [ValidationContext] = []
        var encoding: [EncodingPropertiesContext] = []
    }

    /// generate shape members context
    func generateMembersContexts(_ shape: CollectionShape, shapeName: String, typeIsUnion: Bool) -> MembersContexts {
        var contexts = MembersContexts()
        guard let members = shape.members else { return contexts }
        let isOutputShape = shape.hasTrait(type: SotoOutputShapeTrait.self)
        let isInputShape = shape.hasTrait(type: SotoInputShapeTrait.self)
        let sortedMembers = members.map { $0 }.sorted { $0.key.lowercased() < $1.key.lowercased() }
        for member in sortedMembers {
            // member context
            let memberContext = self.generateMemberContext(member.value, name: member.key, shapeName: shapeName, typeIsUnion: typeIsUnion, isOutputShape: isOutputShape)
            contexts.members.append(memberContext)
            // coding key context
            if let codingKeyContext = generateCodingKeyContext(member.value, name: member.key, isOutputShape: isOutputShape) {
                contexts.codingKeys.append(codingKeyContext)
            }
            // member encoding context
            let memberEncodingContext = self.generateMemberEncodingContext(
                member.value,
                name: member.key,
                isOutputShape: isOutputShape,
                isPropertyWrapper: memberContext.propertyWrapper != nil && isInputShape
            )
            contexts.awsShapeMembers += memberEncodingContext

            // validation context
            if isInputShape {
                if let validationContext = generateValidationContext(member.value, name: member.key) {
                    contexts.validation.append(validationContext)
                }
            }
            if let encodingPropertyContex = generateEncodingPropertyContext(member.value, name: member.key) {
                contexts.encoding.append(encodingPropertyContex)
            }
        }
        return contexts
    }

    func generateMemberContext(_ member: MemberShape, name: String, shapeName: String, typeIsUnion: Bool, isOutputShape: Bool) -> MemberContext {
        var required = member.hasTrait(type: RequiredTrait.self)
        let idempotencyToken = member.hasTrait(type: IdempotencyTokenTrait.self)
        let deprecated = member.hasTrait(type: DeprecatedTrait.self)
        precondition((required && deprecated) == false, "Member cannot be required and deprecated")

        let defaultValue: String?
        if member.hasTrait(type: ClientOptionalTrait.self) {
            required = false
            defaultValue = "nil"
        } else if idempotencyToken == true {
            defaultValue = "\(shapeName.toSwiftClassCase()).idempotencyToken()"
        } else if required {
            if let defaultTrait = member.trait(type: DefaultTrait.self), !isOutputShape {
                switch defaultTrait.value {
                case .boolean(let b):
                    defaultValue = b.description
                case .number(let d):
                    defaultValue = String(format: "%g", d)
                case .string(let s):
                    let shape = self.model.shape(for: member.target)
                    if let enumShape = shape as? EnumShape {
                        guard let enumCase = self.getEnumCaseFromRawValue(enumShape: enumShape, value: .string(s)) else {
                            preconditionFailure("Default enum value does not exist")
                        }
                        defaultValue = ".\(enumCase.toSwiftEnumCase())"
                    } else if shape is BlobShape {
                        if shape?.hasTrait(type: HttpPayloadTrait.self) == true {
                            defaultValue = ".string(\"\(s)\")"
                        } else {
                            defaultValue = ".data(\"\(s)\".utf8)"
                        }
                    } else {
                        defaultValue = "\"\(s)\""
                    }
                case .empty:
                    let shape = self.model.shape(for: member.target)
                    if shape is ListShape {
                        defaultValue = "[]"
                    } else if shape is MapShape {
                        defaultValue = "[:]"
                    } else {
                        defaultValue = nil
                    }
                case .none:
                    defaultValue = nil
                }
            } else {
                defaultValue = nil
            }
        } else {
            defaultValue = "nil"
        }
        let type = member.output(model)
        let optional = (!required && !typeIsUnion)
        return MemberContext(
            variable: name.toSwiftVariableCase(),
            parameter: name.toSwiftLabelCase(),
            required: required,
            default: defaultValue,
            propertyWrapper: self.generatePropertyWrapper(member, name: name, optional: optional),
            type: type + (optional ? "?" : ""),
            comment: processMemberDocs(from: member),
            deprecated: deprecated,
            duplicate: false // TODO: NEED to catch this
        )
    }

    func generateMemberEncodingContext(_ member: MemberShape, name: String, isOutputShape: Bool, isPropertyWrapper: Bool) -> [MemberEncodingContext] {
        var memberEncoding: [MemberEncodingContext] = []
        // if header
        if let headerTrait = member.trait(type: HttpHeaderTrait.self) {
            let name = isPropertyWrapper ? "_\(name.toSwiftLabelCase())" : name.toSwiftLabelCase()
            memberEncoding.append(.init(name: name, location: ".header(\"\(headerTrait.value)\")"))
            // if prefix header
        } else if let headerPrefixTrait = member.trait(type: HttpPrefixHeadersTrait.self) {
            let name = isPropertyWrapper ? "_\(name.toSwiftLabelCase())" : name.toSwiftLabelCase()
            memberEncoding.append(.init(name: name, location: ".headerPrefix(\"\(headerPrefixTrait.value)\")"))
            // if query string
        } else if let queryTrait = member.trait(type: HttpQueryTrait.self) {
            let name = isPropertyWrapper ? "_\(name.toSwiftLabelCase())" : name.toSwiftLabelCase()
            memberEncoding.append(.init(name: name, location: ".querystring(\"\(queryTrait.value)\")"))
            // if part of URL
        } else if member.hasTrait(type: HttpLabelTrait.self) {
            let labelName = isPropertyWrapper ? "_\(name.toSwiftLabelCase())" : name.toSwiftLabelCase()
            let aliasTrait = member.trait(named: serviceProtocolTrait.nameTrait.staticName) as? AliasTrait
            memberEncoding.append(.init(name: labelName, location: ".uri(\"\(aliasTrait?.alias ?? name)\")"))
            // if response status code
        } else if member.hasTrait(type: HttpResponseCodeTrait.self) {
            let name = isPropertyWrapper ? "_\(name.toSwiftLabelCase())" : name.toSwiftLabelCase()
            memberEncoding.append(.init(name: name, location: ".statusCode"))
            // if payload and not a blob or shape is an output shape
        } else if member.hasTrait(type: HttpPayloadTrait.self),
                  !(model.shape(for: member.target) is BlobShape) || isOutputShape
        {
            let aliasTrait = member.traits?.first(where: { $0 is AliasTrait }) as? AliasTrait
            let payloadName = aliasTrait?.alias ?? name
            let swiftLabelName = name.toSwiftLabelCase()
            if swiftLabelName != payloadName {
                let name = isPropertyWrapper ? "_\(name.toSwiftLabelCase())" : name.toSwiftLabelCase()
                memberEncoding.append(.init(name: name, location: ".body(\"\(payloadName)\")"))
            }
        }

        if member.hasTrait(type: HostLabelTrait.self) {
            let labelName = isPropertyWrapper ? "_\(name.toSwiftLabelCase())" : name.toSwiftLabelCase()
            let aliasTrait = member.trait(named: serviceProtocolTrait.nameTrait.staticName) as? AliasTrait
            memberEncoding.append(.init(name: labelName, location: ".hostname(\"\(aliasTrait?.alias ?? name)\")"))
        }
        return memberEncoding
    }

    func generateCodingKeyContext(_ member: MemberShape, name: String, isOutputShape: Bool) -> CodingKeysContext? {
        guard isOutputShape ||
            (!member.hasTrait(type: HttpHeaderTrait.self) &&
                !member.hasTrait(type: HttpPrefixHeadersTrait.self) &&
                !member.hasTrait(type: HttpQueryTrait.self) &&
                !member.hasTrait(type: HttpLabelTrait.self) &&
                !(member.hasTrait(type: HttpPayloadTrait.self) && model.shape(for: member.target) is BlobShape))
        else {
            return nil
        }
        var codingKey: String = name
        if let aliasTrait = member.traits?.first(where: { $0 is AliasTrait }) as? AliasTrait {
            codingKey = aliasTrait.alias
        }
        return CodingKeysContext(variable: name.toSwiftVariableCase(), codingKey: codingKey, duplicate: false)
    }

    /// Generate array/dictionary encoding contexts
    func generateEncodingPropertyContext(_ member: MemberShape, name: String) -> EncodingPropertiesContext? {
        guard let memberShape = model.shape(for: member.target) else { return nil }
        switch memberShape {
        case let list as ListShape:
            guard self.serviceProtocolTrait.requiresCollectionCoders else { return nil }
            let memberName = getListEntryName(member: member, list: list)
            guard let validMemberName = memberName, validMemberName != "member" else { return nil }
            return ArrayEncodingPropertiesContext(name: self.encodingName(name), member: validMemberName)
        case let map as MapShape:
            guard self.serviceProtocolTrait.requiresCollectionCoders else { return nil }
            let names = getMapEntryNames(member: member, map: map)
            guard names.entry != "entry" || names.key != "key" || names.value != "value" else { return nil }
            return DictionaryEncodingPropertiesContext(name: self.encodingName(name), entry: names.entry, key: names.key, value: names.value)
        default:
            return nil
        }
    }

    func generatePropertyWrapper(_ member: MemberShape, name: String, optional: Bool) -> String? {
        let memberShape = model.shape(for: member.target)
        let codingWrapper: String
        if !optional {
            codingWrapper = "@CustomCoding"
        } else {
            codingWrapper = "@OptionalCustomCoding"
        }

        switch memberShape {
        case let list as ListShape:
            guard isMemberInBody(member) else { return nil }
            guard self.serviceProtocolTrait.requiresCollectionCoders else { return nil }
            let memberName = getListEntryName(member: member, list: list)
            guard let validMemberName = memberName else { return nil }
            if self.serviceProtocolTrait is AwsProtocolsEc2QueryTrait {
                if validMemberName == "member" {
                    return "\(codingWrapper)<EC2StandardArrayCoder>"
                } else {
                    return "\(codingWrapper)<EC2ArrayCoder<\(self.encodingName(name)), \(list.member.output(model))>>"
                }
            } else {
                if validMemberName == "member" {
                    return "\(codingWrapper)<StandardArrayCoder>"
                } else {
                    return "\(codingWrapper)<ArrayCoder<\(self.encodingName(name)), \(list.member.output(model))>>"
                }
            }
        case let map as MapShape:
            guard isMemberInBody(member) else { return nil }
            guard self.serviceProtocolTrait.requiresCollectionCoders else { return nil }
            let names = getMapEntryNames(member: member, map: map)
            if names.entry == "entry", names.key == "key", names.value == "value" {
                return "\(codingWrapper)<StandardDictionaryCoder>"
            } else {
                return "\(codingWrapper)<DictionaryCoder<\(self.encodingName(name)), \(map.key.output(model)), \(map.value.output(model))>>"
            }
        case let timestamp as TimestampShape:
            if let formatTrait = timestamp.trait(type: TimestampFormatTrait.self) {
                switch formatTrait.value {
                case .datetime:
                    return "\(codingWrapper)<ISO8601DateCoder>"
                case .epochSeconds:
                    return "\(codingWrapper)<UnixEpochDateCoder>"
                case .httpDate:
                    return "\(codingWrapper)<HTTPHeaderDateCoder>"
                }
            } else if member.hasTrait(type: HttpHeaderTrait.self) {
                return "\(codingWrapper)<HTTPHeaderDateCoder>"
            }
            return nil
        default:
            return nil
        }
    }

    func generateValidationContext(_ shapeId: ShapeId, name: String, required: Bool, container: Bool = false, alreadyProcessed: Set<ShapeId>) -> ValidationContext? {
        guard !alreadyProcessed.contains(shapeId) else { return nil }
        guard let shape = model.shape(for: shapeId) else { return nil }
        guard !shape.hasTrait(type: EnumTrait.self) else { return nil }

        var requirements: [String: Any] = [:]
        if !(shape is EnumShape) {
            if let lengthTrait = shape.trait(type: LengthTrait.self) {
                if let min = lengthTrait.min, min > 0 {
                    requirements["min"] = min
                }
                requirements["max"] = lengthTrait.max
            }
            if let rangeTrait = shape.trait(type: RangeTrait.self) {
                if shape is FloatShape || shape is DoubleShape || shape is BigDecimalShape {
                    requirements["min"] = rangeTrait.min
                    requirements["max"] = rangeTrait.max
                } else {
                    requirements["min"] = rangeTrait.min.map { NSNumber(value: $0).int64Value }
                    requirements["max"] = rangeTrait.max.map { NSNumber(value: $0).int64Value }
                }
            }
            if let patternTrait = shape.trait(type: PatternTrait.self) {
                requirements["pattern"] = "\"\(patternTrait.value.addingBackslashEncoding())\""
            }
        }

        var listMember: MemberShape?
        if let list = shape as? ListShape {
            listMember = list.member
        } else if let set = shape as? SetShape {
            listMember = set.member
        }
        if let listMember = listMember {
            // validation code doesn't support containers inside containers. Only service affected by this is SSM
            if !container {
                if let memberValidationContext = generateValidationContext(
                    listMember.target,
                    name: name,
                    required: required,
                    container: true,
                    alreadyProcessed: alreadyProcessed
                ) {
                    return ValidationContext(
                        name: name.toSwiftVariableCase(),
                        required: required,
                        reqs: requirements,
                        member: memberValidationContext
                    )
                }
            }
        }

        if let map = shape as? MapShape {
            // validation code doesn't support containers inside containers. Only service affected by this is SSM
            if !container {
                let keyValidationContext = self.generateValidationContext(
                    map.key.target,
                    name: name,
                    required: required,
                    container: true,
                    alreadyProcessed: alreadyProcessed
                )
                let valueValidationContext = self.generateValidationContext(
                    map.value.target,
                    name: name,
                    required: required,
                    container: true,
                    alreadyProcessed: alreadyProcessed
                )
                if keyValidationContext != nil || valueValidationContext != nil {
                    return ValidationContext(
                        name: name.toSwiftVariableCase(),
                        required: required,
                        reqs: requirements,
                        keyValidation: keyValidationContext,
                        valueValidation: valueValidationContext
                    )
                }
            }
        }

        if let collection = shape as? CollectionShape, let members = collection.members {
            for member in members {
                let memberRequired = member.value.hasTrait(type: RequiredTrait.self) && !member.value.hasTrait(type: ClientOptionalTrait.self)
                var alreadyProcessed2 = alreadyProcessed
                alreadyProcessed2.insert(shapeId)
                if self.generateValidationContext(
                    member.value.target,
                    name: member.key,
                    required: memberRequired,
                    container: false,
                    alreadyProcessed: alreadyProcessed2
                ) != nil {
                    return ValidationContext(name: name.toSwiftVariableCase(), shape: true, required: required)
                }
            }
        }
        if requirements.count > 0 {
            return ValidationContext(name: name.toSwiftVariableCase(), required: required, reqs: requirements)
        }
        return nil
    }

    func generateValidationContext(_ member: MemberShape, name: String) -> ValidationContext? {
        let required = member.hasTrait(type: RequiredTrait.self) && !member.hasTrait(type: ClientOptionalTrait.self)
        return self.generateValidationContext(member.target, name: name, required: required, container: false, alreadyProcessed: [])
    }

    /// return Enum case string from enum value
    func getEnumCaseFromRawValue(enumShape: EnumShape, value: EnumValueTrait.EnumValue) -> String? {
        guard let members = enumShape.members else { return nil }
        for e in members.enumerated() {
            let enumValue = e.element.value.trait(type: EnumValueTrait.self)
            if value == enumValue?.value {
                return e.element.key
            }
        }
        return nil
    }
}
