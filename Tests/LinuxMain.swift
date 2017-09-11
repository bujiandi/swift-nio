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
///
/// LinuxMain.swift
///
import XCTest

///
/// NOTE: This file was generated by generate_linux_tests.rb
///
/// Do NOT edit this file directly as it will be regenerated automatically when needed.
///

#if os(Linux) || os(FreeBSD)
   @testable import NIOHTTP1Tests
   @testable import NIOTests

   XCTMain([
         testCase(HTTPHeadersTest.allTests),
         testCase(HTTPTest.allTests),
         testCase(CircularBufferTests.allTests),
         testCase(TypeAssistedChannelHandlerTest.allTests),
         testCase(ByteBufferTest.allTests),
         testCase(ChannelPipelineTest.allTests),
         testCase(ByteToMessageDecoderTest.allTests),
         testCase(MessageToByteEncoderTest.allTests),
         testCase(EchoServerClientTest.allTests),
         testCase(EmbeddedChannelTest.allTests),
         testCase(EventLoopTest.allTests),
         testCase(FileRegionTest.allTests),
         testCase(FutureTest.allTests),
         testCase(AdaptiveRecvByteBufferAllocatorTest.allTests),
         testCase(SocketAddressTest.allTests),
    ])
#endif