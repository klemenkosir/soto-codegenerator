//===----------------------------------------------------------------------===//
//
// This source file is part of the Soto for AWS open source project
//
// Copyright (c) 2017-2021 the Soto project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.txt for the list of Soto project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

extension Templates {
    static let apiTemplate =
        #"""
        {{%CONTENT_TYPE:TEXT}}
        {{>header}}

        @_exported import SotoCore

        {{#middlewareFramework}}
        import {{ . }}

        {{/middlewareFramework}}
        /// Service object for interacting with AWS {{name}} service.
        {{#first(description)}}
        ///
        {{#description}}
        /// {{.}}
        {{/description}}
        {{/first(description)}}
        {{scope}} struct {{ name }}: AWSService {
            // MARK: Member variables

            /// Client used for communication with AWS
            {{scope}} let client: AWSClient
            /// Service configuration
            {{scope}} let config: AWSServiceConfig
        {{#endpointDiscovery}}
            /// endpoint storage
            let endpointStorage: AWSEndpointStorage
        {{/endpointDiscovery}}

            // MARK: Initialization

            /// Initialize the {{name}} client
            /// - parameters:
            ///     - client: AWSClient used to process requests
        {{#regionalized}}
            ///     - region: Region of server you want to communicate with. This will override the partition parameter.
        {{/regionalized}}
            ///     - partition: AWS partition where service resides, standard (.aws), china (.awscn), government (.awsusgov).
            ///     - endpoint: Custom endpoint URL to use instead of standard AWS servers
            ///     - timeout: Timeout value for HTTP requests
            {{scope}} init(
                client: AWSClient,
        {{#regionalized}}
                region: SotoCore.Region? = nil,
        {{/regionalized}}
                partition: AWSPartition = .aws,
                endpoint: String? = nil,
                timeout: TimeAmount? = nil,
                byteBufferAllocator: ByteBufferAllocator = ByteBufferAllocator(),
                options: AWSServiceConfig.Options = []
            ) {
                self.client = client
                self.config = AWSServiceConfig(
        {{#regionalized}}
                    region: region,
                    partition: region?.partition ?? partition,
        {{/regionalized}}
        {{^regionalized}}
                    region: nil,
                    partition: partition,
        {{/regionalized}}
        {{#amzTarget}}
                    amzTarget: "{{.}}",
        {{/amzTarget}}
                    service: "{{endpointPrefix}}",
        {{#signingName}}
                    signingName: "{{.}}",
        {{/signingName}}
                    serviceProtocol: {{protocol}},
                    apiVersion: "{{apiVersion}}",
                    endpoint: endpoint,
        {{#first(serviceEndpoints)}}
                    serviceEndpoints: [
        {{#serviceEndpoints}}
                        {{.}}{{^last()}}, {{/last()}}
        {{/serviceEndpoints}}
                    ],
        {{/first(serviceEndpoints)}}
        {{#first(partitionEndpoints)}}
                    partitionEndpoints: [
        {{#partitionEndpoints}}
                        {{.}}{{^last()}}, {{/last()}}
        {{/partitionEndpoints}}
                    ],
        {{/first(partitionEndpoints)}}
        {{#first(variantEndpoints)}}
                    variantEndpoints: [
        {{#variantEndpoints}}
                        [{{variant}}]: .init(endpoints: [
        {{#endpoints.endpoints}}
                            "{{region}}": "{{hostname}}"{{^last()}}, {{/last()}}
        {{/endpoints.endpoints}}
                        ]){{^last()}}, {{/last()}}
        {{/variantEndpoints}}
                    ],
        {{/first(variantEndpoints)}}
        {{#errorTypes}}
                    errorType: {{.}}.self,
        {{/errorTypes}}
        {{#xmlNamespace}}
                    xmlNamespace: "{{.}}",
        {{/xmlNamespace}}
        {{#middlewareClass}}
                    middlewares: {{.}},
        {{/middlewareClass}}
                    timeout: timeout,
                    byteBufferAllocator: byteBufferAllocator,
                    options: options
                )
                {{#endpointDiscovery}}
                    self.endpointStorage = .init(endpoint: self.config.endpoint)
                {{/endpointDiscovery}}
            }

            // MARK: API Calls
        {{#operations}}

        {{#comment}}
            /// {{.}}
        {{/comment}}
        {{#documentationUrl}}
            /// {{.}}
        {{/documentationUrl}}
        {{#deprecated}}
            @available(*, deprecated, message:"{{.}}")
        {{/deprecated}}
            {{^outputShape}}@discardableResult {{/outputShape}}{{scope}} func {{funcName}}({{#inputShape}}_ input: {{.}}, {{/inputShape}}logger: {{logger}} = AWSClient.loggingDisabled, on eventLoop: EventLoop? = nil) -> EventLoopFuture<{{#outputShape}}{{.}}{{/outputShape}}{{^outputShape}}Void{{/outputShape}}> {
                return self.client.execute(operation: "{{name}}", path: "{{path}}", httpMethod: .{{httpMethod}}, serviceConfig: self.config{{#inputShape}}, input: input{{/inputShape}}{{#endpointRequired}}, endpointDiscovery: .init(storage: self.endpointStorage, discover: self.getEndpoint, required: {{required}}){{/endpointRequired}}{{#hostPrefix}}, hostPrefix: "{{{.}}}"{{/hostPrefix}}, logger: logger, on: eventLoop)
            }
        {{/operations}}
        {{#first(streamingOperations)}}

            // MARK: Streaming API Calls
        {{#streamingOperations}}

        {{#comment}}
            /// {{.}}
        {{/comment}}
        {{#documentationUrl}}
            /// {{.}}
        {{/documentationUrl}}
        {{#deprecated}}
            @available(*, deprecated, message:"{{.}}")
        {{/deprecated}}
            {{^outputShape}}@discardableResult {{/outputShape}}{{scope}} func {{funcName}}Streaming({{#inputShape}}_ input: {{.}}, {{/inputShape}}logger: {{logger}} = AWSClient.loggingDisabled, on eventLoop: EventLoop? = nil{{#streaming}}, _ stream: @escaping ({{.}}, EventLoop)->EventLoopFuture<Void>{{/streaming}}) -> EventLoopFuture<{{#outputShape}}{{.}}{{/outputShape}}{{^outputShape}}Void{{/outputShape}}> {
                return self.client.execute(operation: "{{name}}", path: "{{path}}", httpMethod: .{{httpMethod}}, serviceConfig: self.config{{#inputShape}}, input: input{{/inputShape}}{{#endpointRequired}}, endpointDiscovery: .init(storage: self.endpointStorage, discover: self.getEndpoint, required: {{required}}){{/endpointRequired}}{{#hostPrefix}}, hostPrefix: "{{{.}}}"{{/hostPrefix}}, logger: logger, on: eventLoop{{#streaming}}, stream: stream{{/streaming}})
            }
        {{/streamingOperations}}
        {{/first(streamingOperations)}}
        {{#endpointDiscovery}}

            func getEndpoint(logger: Logger, eventLoop: EventLoop) -> EventLoopFuture<AWSEndpoints> {
                return describeEndpoints(.init(), logger: logger, on: eventLoop).map {
                    .init(endpoints: $0.endpoints.map {
                        .init(address: "https://\($0.address)", cachePeriodInMinutes: $0.cachePeriodInMinutes)
                    })
                }
            }
        {{/endpointDiscovery}}
        }

        extension {{ name }} {
            /// Initializer required by `AWSService.with(middlewares:timeout:byteBufferAllocator:options)`. You are not able to use this initializer directly as there are no {{scope}}
            /// initializers for `AWSServiceConfig.Patch`. Please use `AWSService.with(middlewares:timeout:byteBufferAllocator:options)` instead.
            {{scope}} init(from: {{ name }}, patch: AWSServiceConfig.Patch) {
                self.client = from.client
                self.config = from.config.with(patch: patch)
            {{#endpointDiscovery}}
                self.endpointStorage = .init(endpoint: self.config.endpoint)
            {{/endpointDiscovery}}
            }
        }

        {{#paginators}}
        {{>paginators}}
        {{/paginators}}

        {{#waiters}}
        {{>waiters}}
        {{/waiters}}
        """#
}
