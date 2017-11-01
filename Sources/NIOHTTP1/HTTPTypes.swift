//===----------------------------------------------------------------------===//
//
// This source file is part of the SwiftNIO open source project
//
// Copyright (c) 2017-2018 Apple Inc. and the SwiftNIO project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.txt for the list of SwiftNIO project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

import NIO

let crlf: StaticString = "\r\n"
let headerSeparator: StaticString = ": "
let http1_1: StaticString = "HTTP/1.1"
let status200: StaticString = "200 OK"

public struct HTTPRequestHead: Equatable {
    public static func ==(lhs: HTTPRequestHead, rhs: HTTPRequestHead) -> Bool {
        return lhs.method == rhs.method && lhs.uri == rhs.uri && lhs.version == rhs.version && lhs.headers == rhs.headers
    }

    public let method: HTTPMethod
    public let uri: String
    public let version: HTTPVersion
    public var headers: HTTPHeaders

    public init(version: HTTPVersion, method: HTTPMethod, uri: String) {
        self.version = version
        self.method = method
        self.uri = uri
        self.headers = HTTPHeaders()
    }

    init(version: HTTPVersion, method: HTTPMethod, uri: String, headers: HTTPHeaders) {
        self.version = version
        self.method = method
        self.uri = uri
        self.headers = headers
    }
}

public enum HTTPRequestPart: Equatable {
    case head(HTTPRequestHead)
    case body(ByteBuffer)
    case end(HTTPHeaders?)

    public static func ==(lhs: HTTPRequestPart, rhs: HTTPRequestPart) -> Bool {
        switch (lhs, rhs) {
        case (.head(let h1), .head(let h2)):
            return h1 == h2
        case (.body(let b1), .body(let b2)):
            return b1 == b2
        case (.end(let h1), .end(let h2)):
            return h1 == h2
        default:
            return false
        }
    }
}

public extension HTTPRequestHead {
    var isKeepAlive: Bool {
        guard let connection = headers["connection"].first?.lowercased() else {
            // HTTP 1.1 use keep-alive by default if not otherwise told.
            return version.major == 1 && version.minor == 1
        }

        if connection == "close" {
            return false
        }
        return connection == "keep-alive"
    }
}

public enum HTTPResponsePart {
    case head(HTTPResponseHead)
    case body(IOData)
    case end(HTTPHeaders?)
}

public struct HTTPResponseHead {
    public let status: HTTPResponseStatus
    public let version: HTTPVersion
    public var headers: HTTPHeaders = HTTPHeaders()

    public init(version: HTTPVersion, status: HTTPResponseStatus) {
        self.version = version
        self.status = status
    }
}

fileprivate typealias HTTPHeadersStorage = [String:[(String, String)]] // [lowerCasedName: [(originalCaseName, value)]


struct HTTPHeadersIterator : IteratorProtocol {
    fileprivate var storageIterator: HTTPHeadersStorage.Iterator
    fileprivate var valuesIterator: Array<(String, String)>.Iterator?

    fileprivate init(wrapping: HTTPHeadersStorage.Iterator) {
        self.storageIterator = wrapping
    }

    mutating func next() -> (name: String, value: String)? {
        // If we're already iterating an entry in the dict, grab the next one
        if let nextValues = valuesIterator?.next() {
            return nextValues
        } else {
            // If there's nothing left in this array, clear the iterator
            valuesIterator = nil
        }

        if let entry = storageIterator.next() {
            valuesIterator = entry.value.makeIterator()
            return next()
        } else {
            return nil
        }
    }
}

public struct HTTPHeaders : Sequence, CustomStringConvertible {

    // [lowerCasedName: [(originalCaseName, value)]
    private var storage: HTTPHeadersStorage = HTTPHeadersStorage()
    public var description: String { return storage.description }

    // This is expressly *not* public because it doesn't do anything sensible:
    // it doesn't return the number of header fields in the structure, just the number
    // of unique header names. That's not really a useful question to ask, but we need it
    // in NIOHTTP1 so we're adding it internally. At some point this type should be made
    // to conform to Collection, and when that's done we can add something a bit more sensible.
    var count: Int {
        return storage.count
    }

    public init(_ headers: [(String, String)] = []) {
        for (key, value) in headers {
            add(name: key, value: value)
        }
    }

    public mutating func add(name: String, value: String) {
        let keyLower = name.lowercased()
        storage[keyLower] = (storage[keyLower] ?? [])  + [(name, value)]
    }

    public mutating func replaceOrAdd(name: String, value: String) {
        let keyLower = name.lowercased()
        storage[keyLower] = [(name, value)]
    }

    public mutating func remove(name: String) {
        self.storage[name.lowercased()] = nil
    }

    public subscript(name: String) -> [String] {
        if let result = storage[name.lowercased()] {
            return result.map { tuple in tuple.1 }
        }
        return []
    }

    func write(buffer: inout ByteBuffer) {
        for (key, values) in storage {
            if key != "set-cookie" {
                writeListHeaderValues(buffer: &buffer, key: key, values: values)
            } else {
                writeSequentialHeaderValues(buffer: &buffer, key: key, values: values)
            }
        }
        buffer.write(staticString: crlf)
    }

    /// Used for most HTTP headers, which can be represented as a single line joined by commas.
    private func writeListHeaderValues(buffer: inout ByteBuffer, key: String, values: [(String, String)]) {
        buffer.write(string: key)
        buffer.write(staticString: headerSeparator)

        var writerIndex = buffer.writerIndex
        for (_, value) in values {
            buffer.write(string: value)
            writerIndex = buffer.writerIndex
            buffer.write(staticString: ",")
        }
        // Discard last ,
        buffer.moveWriterIndex(to: writerIndex)
        buffer.write(staticString: crlf)
    }

    /// Used for HTTP headers that cannot be joined with commas, e.g. set-cookie.
    private func writeSequentialHeaderValues(buffer: inout ByteBuffer, key: String, values: [(String, String)]) {
        for (_, value) in values {
            buffer.write(string: key)
            buffer.write(staticString: headerSeparator)
            buffer.write(string: value)
            buffer.write(staticString: crlf)
        }
    }

    public func makeIterator() -> AnyIterator<(name: String, value: String)> {
        return AnyIterator(HTTPHeadersIterator(wrapping: storage.makeIterator()))
    }

    /// Retrieves the header values for the given header field in "canonical form": that is,
    /// splitting them on commas as extensively as possible such that multiple values received on the
    /// one line are returned as separate entries. Also respects the fact that Set-Cookie should not
    /// be split in this way.
    public func getCanonicalForm(_ name: String) -> [String] {
        // It's not safe to split Set-Cookie on comma.
        let queryName = name.lowercased()
        if queryName == "set-cookie" {
            return self[name]
        }

        if let result = storage[queryName] {
            return result.map { tuple in tuple.1.split(separator: ",").map { substring in String(substring).trimmingCharacters(in: .whitespaces) } }.reduce([], +)
        }
        return []
    }
}

extension HTTPHeaders : Equatable {
    public static func ==(lhs: HTTPHeaders, rhs: HTTPHeaders) -> Bool {
        if lhs.storage.count != rhs.storage.count {
            return false
        }
        for (k, v) in lhs.storage {
            if let rv = rhs.storage[k], rv.map({ $0.1 }) == v.map({ $0.1 }) {
                continue
            } else {
                return false
            }
        }
        return true
    }
}

public enum HTTPMethod: Equatable {
    public static func ==(lhs: HTTPMethod, rhs: HTTPMethod) -> Bool {
        switch (lhs, rhs){
        case (.GET, .GET):
            return true
        case (.PUT, .PUT):
            return true
        case (.ACL, .ACL):
            return true
        case (.HEAD, .HEAD):
            return true
        case (.POST, .POST):
            return true
        case (.COPY, .COPY):
            return true
        case (.LOCK, .LOCK):
            return true
        case (.MOVE, .MOVE):
            return true
        case (.BIND, .BIND):
            return true
        case (.LINK, .LINK):
            return true
        case (.PATCH, .PATCH):
            return true
        case (.TRACE, .TRACE):
            return true
        case (.MKCOL, .MKCOL):
            return true
        case (.MERGE, .MERGE):
            return true
        case (.PURGE, .PURGE):
            return true
        case (.NOTIFY, .NOTIFY):
            return true
        case (.SEARCH, .SEARCH):
            return true
        case (.UNLOCK, .UNLOCK):
            return true
        case (.REBIND, .REBIND):
            return true
        case (.UNBIND, .UNBIND):
            return true
        case (.REPORT, .REPORT):
            return true
        case (.DELETE, .DELETE):
            return true
        case (.UNLINK, .UNLINK):
            return true
        case (.CONNECT, .CONNECT):
            return true
        case (.MSEARCH, .MSEARCH):
            return true
        case (.OPTIONS, .OPTIONS):
            return true
        case (.PROPFIND, .PROPFIND):
            return true
        case (.CHECKOUT, .CHECKOUT):
            return true
        case (.PROPPATCH, .PROPPATCH):
            return true
        case (.SUBSCRIBE, .SUBSCRIBE):
            return true
        case (.MKCALENDAR, .MKCALENDAR):
            return true
        case (.MKACTIVITY, .MKACTIVITY):
            return true
        case (.UNSUBSCRIBE, .UNSUBSCRIBE):
            return true
        case (.RAW(let l), .RAW(let r)):
            return l == r
        default:
            return false
        }
    }

    case GET
    case PUT
    case ACL
    case HEAD
    case POST
    case COPY
    case LOCK
    case MOVE
    case BIND
    case LINK
    case PATCH
    case TRACE
    case MKCOL
    case MERGE
    case PURGE
    case NOTIFY
    case SEARCH
    case UNLOCK
    case REBIND
    case UNBIND
    case REPORT
    case DELETE
    case UNLINK
    case CONNECT
    case MSEARCH
    case OPTIONS
    case PROPFIND
    case CHECKOUT
    case PROPPATCH
    case SUBSCRIBE
    case MKCALENDAR
    case MKACTIVITY
    case UNSUBSCRIBE
    case RAW(value: String)
}

public struct HTTPVersion: Equatable {
    public static func ==(lhs: HTTPVersion, rhs: HTTPVersion) -> Bool {
        return lhs.major == rhs.major && lhs.minor == rhs.minor
    }

    public init(major: UInt16, minor: UInt16) {
        self.major = major
        self.minor = minor
    }

    public let major: UInt16
    public let minor: UInt16
}

extension HTTPVersion {
    func write(buffer: inout ByteBuffer) {
        if major == 1 && minor == 1 {
            // Optimize for HTTP/1.1
            buffer.write(staticString: http1_1)
        } else {
            buffer.write(staticString: "HTTP/")
            buffer.write(string: String(major))
            buffer.write(staticString: ".")
            buffer.write(string: String(minor))
        }
    }
}

extension HTTPParserError: CustomDebugStringConvertible {
    public var debugDescription: String {
        switch self {
        case .invalidCharactersUsed:
            return "illegal characters used in URL/headers"
        case .trailingGarbage:
            return "trailing garbage bytes"
        case .invalidEOFState:
            return "stream ended at an unexpected time"
        case .headerOverflow:
            return "too many header bytes seen; overflow detected"
        case .closedConnection:
            return "data received after completed connection: close message"
        case .invalidVersion:
            return "invalid HTTP version"
        case .invalidStatus:
            return "invalid HTTP status code"
        case .invalidMethod:
            return "invalid HTTP method"
        case .invalidURL:
            return "invalid URL"
        case .invalidHost:
            return "invalid host"
        case .invalidPort:
            return  "invalid port"
        case .invalidPath:
            return "invalid path"
        case .invalidQueryString:
            return "invalid query string"
        case .invalidFragment:
            return "invalid fragment"
        case .lfExpected:
            return "LF character expected"
        case .invalidHeaderToken:
            return "invalid character in header"
        case .invalidContentLength:
            return "invalid character in content-length header"
        case .unexpectedContentLength:
            return "unexpected content-length header"
        case .invalidChunkSize:
            return "invalid character in chunk size header"
        case .invalidConstant:
            return "invalid constant string"
        case .invalidInternalState:
            return "invalid internal state (swift-http-parser error)"
        case .strictModeAssertion:
            return "strict mode assertion"
        case .paused:
            return "paused (swift-http-parser error)"
        case .unknown:
            return "unknown (http_parser error)"
        }
    }
}

public enum HTTPParserError: Error {
    case invalidCharactersUsed
    case trailingGarbage
    /* from CHTTPParser */
    case invalidEOFState
    case headerOverflow
    case closedConnection
    case invalidVersion
    case invalidStatus
    case invalidMethod
    case invalidURL
    case invalidHost
    case invalidPort
    case invalidPath
    case invalidQueryString
    case invalidFragment
    case lfExpected
    case invalidHeaderToken
    case invalidContentLength
    case unexpectedContentLength
    case invalidChunkSize
    case invalidConstant
    case invalidInternalState
    case strictModeAssertion
    case paused
    case unknown
}

extension HTTPResponseStatus {
    public var code: UInt {
        get {
            switch self {
            case .continue:
                return 100
            case .switchingProtocols:
                return 101
            case .processing:
                return 102
            case .ok:
                return 200
            case .created:
                return 201
            case .accepted:
                return 202
            case .nonAuthoritativeInformation:
                return 203
            case .noContent:
                return 204
            case .resetContent:
                return 205
            case .partialContent:
                return 206
            case .multiStatus:
                return 207
            case .alreadyReported:
                return 208
            case .imUsed:
                return 226
            case .multipleChoices:
                return 300
            case .movedPermanently:
                return 301
            case .found:
                return 302
            case .seeOther:
                return 303
            case .notModified:
                return 304
            case .useProxy:
                return 305
            case .temporaryRedirect:
                return 307
            case .permanentRedirect:
                return 308
            case .badRequest:
                return 400
            case .unauthorized:
                return 401
            case .paymentRequired:
                return 402
            case .forbidden:
                return 403
            case .notFound:
                return 404
            case .methodNotAllowed:
                return 405
            case .notAcceptable:
                return 406
            case .proxyAuthenticationRequired:
                return 407
            case .requestTimeout:
                return 408
            case .conflict:
                return 409
            case .gone:
                return 410
            case .lengthRequired:
                return 411
            case .preconditionFailed:
                return 412
            case .payloadTooLarge:
                return 413
            case .uriTooLong:
                return 414
            case .unsupportedMediaType:
                return 415
            case .rangeNotSatisfiable:
                return 416
            case .expectationFailed:
                return 417
            case .misdirectedRequest:
                return 421
            case .unprocessableEntity:
                return 422
            case .locked:
                return 423
            case .failedDependency:
                return 424
            case .upgradeRequired:
                return 426
            case .preconditionRequired:
                return 428
            case .tooManyRequests:
                return 429
            case .requestHeaderFieldsTooLarge:
                return 431
            case .unavailableForLegalReasons:
                return 451
            case .internalServerError:
                return 500
            case .notImplemented:
                return 501
            case .badGateway:
                return 502
            case .serviceUnavailable:
                return 503
            case .gatewayTimeout:
                return 504
            case .httpVersionNotSupported:
                return 505
            case .variantAlsoNegotiates:
                return 506
            case .insufficientStorage:
                return 507
            case .loopDetected:
                return 508
            case .notExtended:
                return 510
            case .networkAuthenticationRequired:
                return 511
            case .custom(code: let code, reasonPhrase: _):
                return code
            }
        }
    }

    public var reasonPhrase: String {
        get {
            switch self {
            case .continue:
                return "Continue"
            case .switchingProtocols:
                return "Switching Protocols"
            case .processing:
                return "Processing"
            case .ok:
                return "OK"
            case .created:
                return "Created"
            case .accepted:
                return "Accepted"
            case .nonAuthoritativeInformation:
                return "Non-Authoritative Information"
            case .noContent:
                return "No Content"
            case .resetContent:
                return "Reset Content"
            case .partialContent:
                return "Partial Content"
            case .multiStatus:
                return "Multi-Status"
            case .alreadyReported:
                return "Already Reported"
            case .imUsed:
                return "IM Used"
            case .multipleChoices:
                return "Multiple Choices"
            case .movedPermanently:
                return "Moved Permanently"
            case .found:
                return "Found"
            case .seeOther:
                return "See Other"
            case .notModified:
                return "Not Modified"
            case .useProxy:
                return "Use Proxy"
            case .temporaryRedirect:
                return "Temporary Redirect"
            case .permanentRedirect:
                return "Permanent Redirect"
            case .badRequest:
                return "Bad Request"
            case .unauthorized:
                return "Unauthorized"
            case .paymentRequired:
                return "Payment Required"
            case .forbidden:
                return "Forbidden"
            case .notFound:
                return "Not Found"
            case .methodNotAllowed:
                return "Method Not Allowed"
            case .notAcceptable:
                return "Not Acceptable"
            case .proxyAuthenticationRequired:
                return "Proxy Authentication Required"
            case .requestTimeout:
                return "Request Timeout"
            case .conflict:
                return "Conflict"
            case .gone:
                return "Gone"
            case .lengthRequired:
                return "Length Required"
            case .preconditionFailed:
                return "Precondition Failed"
            case .payloadTooLarge:
                return "Payload Too Large"
            case .uriTooLong:
                return "URI Too Long"
            case .unsupportedMediaType:
                return "Unsupported Media Type"
            case .rangeNotSatisfiable:
                return "Range Not Satisfiable"
            case .expectationFailed:
                return "Expectation Failed"
            case .misdirectedRequest:
                return "Misdirected Request"
            case .unprocessableEntity:
                return "Unprocessable Entity"
            case .locked:
                return "Locked"
            case .failedDependency:
                return "Failed Dependency"
            case .upgradeRequired:
                return "Upgrade Required"
            case .preconditionRequired:
                return "Precondition Required"
            case .tooManyRequests:
                return "Too Many Requests"
            case .requestHeaderFieldsTooLarge:
                return "Request Header Fields Too Large"
            case .unavailableForLegalReasons:
                return "Unavailable For Legal Reasons"
            case .internalServerError:
                return "Internal Server Error"
            case .notImplemented:
                return "Not Implemented"
            case .badGateway:
                return "Bad Gateway"
            case .serviceUnavailable:
                return "Service Unavailable"
            case .gatewayTimeout:
                return "Gateway Timeout"
            case .httpVersionNotSupported:
                return "HTTP Version Not Supported"
            case .variantAlsoNegotiates:
                return "Variant Also Negotiates"
            case .insufficientStorage:
                return "Insufficient Storage"
            case .loopDetected:
                return "Loop Detected"
            case .notExtended:
                return "Not Extended"
            case .networkAuthenticationRequired:
                return "Network Authentication Required"
            case .custom(code: _, reasonPhrase: let phrase):
                return phrase
            }
        }
    }

    func write(buffer: inout ByteBuffer) {
        switch self {
        case .ok:
            // Optimize for 200 ok, which should be the most likely code (...hopefully).
            buffer.write(staticString: status200)
        default:
            buffer.write(string: String(code))
            buffer.write(string: " ")
            buffer.write(string: reasonPhrase)
        }
    }
}

public enum HTTPResponseStatus: Equatable {
    /* use custom if you want to use a non-standard response code or
     have it available in a (UInt, String) pair from a higher-level web framework. */
    case custom(code: UInt, reasonPhrase: String)

    /* all the codes from http://www.iana.org/assignments/http-status-codes */

    // 1xx
    case `continue`
    case switchingProtocols
    case processing

    // 2xx
    case ok
    case created
    case accepted
    case nonAuthoritativeInformation
    case noContent
    case resetContent
    case partialContent

    // 3xx
    case multiStatus
    case alreadyReported
    case imUsed
    case multipleChoices
    case movedPermanently
    case found
    case seeOther
    case notModified
    case useProxy
    case temporaryRedirect
    case permanentRedirect

    // 4xx
    case badRequest
    case unauthorized
    case paymentRequired
    case forbidden
    case notFound
    case methodNotAllowed
    case notAcceptable
    case proxyAuthenticationRequired
    case requestTimeout
    case conflict
    case gone
    case lengthRequired
    case preconditionFailed
    case payloadTooLarge
    case uriTooLong
    case unsupportedMediaType
    case rangeNotSatisfiable
    case expectationFailed

    // 5xx
    case misdirectedRequest
    case unprocessableEntity
    case locked
    case failedDependency
    case upgradeRequired
    case preconditionRequired
    case tooManyRequests
    case requestHeaderFieldsTooLarge
    case unavailableForLegalReasons
    case internalServerError
    case notImplemented
    case badGateway
    case serviceUnavailable
    case gatewayTimeout
    case httpVersionNotSupported
    case variantAlsoNegotiates
    case insufficientStorage
    case loopDetected
    case notExtended
    case networkAuthenticationRequired

    public var mayHaveResponseBody: Bool {
        switch self {
        case .`continue`,
             .switchingProtocols,
             .processing,
             .noContent,
             .custom where (code < 200) && (code >= 100):
            return false
        default:
            return true
        }
    }
}

public func ==(lhs: HTTPResponseStatus, rhs: HTTPResponseStatus) -> Bool {
    switch (lhs, rhs) {
    case (.custom(let lcode, let lreason), .custom(let rcode, let rreason)):
        return lcode == rcode && lreason == rreason
    case (.continue, .continue):
        return true
    case (.switchingProtocols, .switchingProtocols):
        return true
    case (.processing, .processing):
        return true
    case (.ok, .ok):
        return true
    case (.created, .created):
        return true
    case (.accepted, .accepted):
        return true
    case (.nonAuthoritativeInformation, .nonAuthoritativeInformation):
        return true
    case (.noContent, .noContent):
        return true
    case (.resetContent, .resetContent):
        return true
    case (.partialContent, .partialContent):
        return true
    case (.multiStatus, .multiStatus):
        return true
    case (.alreadyReported, .alreadyReported):
        return true
    case (.imUsed, .imUsed):
        return true
    case (.multipleChoices, .multipleChoices):
        return true
    case (.movedPermanently, .movedPermanently):
        return true
    case (.found, .found):
        return true
    case (.seeOther, .seeOther):
        return true
    case (.notModified, .notModified):
        return true
    case (.useProxy, .useProxy):
        return true
    case (.temporaryRedirect, .temporaryRedirect):
        return true
    case (.permanentRedirect, .permanentRedirect):
        return true
    case (.badRequest, .badRequest):
        return true
    case (.unauthorized, .unauthorized):
        return true
    case (.paymentRequired, .paymentRequired):
        return true
    case (.forbidden, .forbidden):
        return true
    case (.notFound, .notFound):
        return true
    case (.methodNotAllowed, .methodNotAllowed):
        return true
    case (.notAcceptable, .notAcceptable):
        return true
    case (.proxyAuthenticationRequired, .proxyAuthenticationRequired):
        return true
    case (.requestTimeout, .requestTimeout):
        return true
    case (.conflict, .conflict):
        return true
    case (.gone, .gone):
        return true
    case (.lengthRequired, .lengthRequired):
        return true
    case (.preconditionFailed, .preconditionFailed):
        return true
    case (.payloadTooLarge, .payloadTooLarge):
        return true
    case (.uriTooLong, .uriTooLong):
        return true
    case (.unsupportedMediaType, .unsupportedMediaType):
        return true
    case (.rangeNotSatisfiable, .rangeNotSatisfiable):
        return true
    case (.expectationFailed, .expectationFailed):
        return true
    case (.misdirectedRequest, .misdirectedRequest):
        return true
    case (.unprocessableEntity, .unprocessableEntity):
        return true
    case (.locked, .locked):
        return true
    case (.failedDependency, .failedDependency):
        return true
    case (.upgradeRequired, .upgradeRequired):
        return true
    case (.preconditionRequired, .preconditionRequired):
        return true
    case (.tooManyRequests, .tooManyRequests):
        return true
    case (.requestHeaderFieldsTooLarge, .requestHeaderFieldsTooLarge):
        return true
    case (.unavailableForLegalReasons, .unavailableForLegalReasons):
        return true
    case (.internalServerError, .internalServerError):
        return true
    case (.notImplemented, .notImplemented):
        return true
    case (.badGateway, .badGateway):
        return true
    case (.serviceUnavailable, .serviceUnavailable):
        return true
    case (.gatewayTimeout, .gatewayTimeout):
        return true
    case (.httpVersionNotSupported, .httpVersionNotSupported):
        return true
    case (.variantAlsoNegotiates, .variantAlsoNegotiates):
        return true
    case (.insufficientStorage, .insufficientStorage):
        return true
    case (.loopDetected, .loopDetected):
        return true
    case (.notExtended, .notExtended):
        return true
    case (.networkAuthenticationRequired, .networkAuthenticationRequired):
        return true
    default:
        return false
    }
}
