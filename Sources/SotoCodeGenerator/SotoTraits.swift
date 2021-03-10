//===----------------------------------------------------------------------===//
//
// This source file is part of the Soto for AWS open source project
//
// Copyright (c) 2017-2020 the Soto project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.txt for the list of Soto project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

// traits used by the Soto code generator.

import SotoSmithy

struct SotoInputShapeTrait: StaticTrait {
    static let staticName: ShapeId = "soto.api#inputShape"
}

struct SotoOutputShapeTrait: StaticTrait {
    static let staticName: ShapeId = "soto.api#outputShape"
}

struct SotoAuthUnsignedPayloadTrait: StaticTrait {
    static let staticName: ShapeId = "soto.api#unsignedPayload"
    var selector: Selector { TypeSelector<StructureShape>() }
}

struct SotoExtensibleEnumTrait: StaticTrait {
    static let staticName: ShapeId = "soto.api#extensibleEnum"
    var selector: Selector { TraitSelector<EnumTrait>() }
}
