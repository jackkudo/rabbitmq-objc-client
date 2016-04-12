import XCTest

class RMQConnectionTest: XCTestCase {

    func startedConnection(
        transport: RMQTransport,
        syncTimeout: Double = 0,
        user: String = "foo",
        password: String = "bar",
        vhost: String = "baz"
        ) -> RMQConnection {
        let conn = RMQConnection(
            transport: transport,
            user: user,
            password: password,
            vhost: vhost,
            channelMax: 65535,
            frameMax: 131072,
            heartbeat: 0,
            syncTimeout: syncTimeout,
            delegate: nil,
            delegateQueue: dispatch_get_main_queue()
        )
        conn.start()
        return conn
    }

    func testConnectionErrorOnConnectIsSentToDelegate() {
        let transport = ControlledInteractionTransport()
        transport.stubbedToThrowErrorOnConnect = "bad connection"
        let delegate = ConnectionDelegateSpy()
        let queueHelper = QueueHelper()
        let conn = RMQConnection(
            transport: transport,
            user: "foo",
            password: "bar",
            vhost: "",
            channelMax: 123,
            frameMax: 321,
            heartbeat: 10,
            syncTimeout: 1,
            delegate: delegate,
            delegateQueue: queueHelper.dispatchQueue
        )
        conn.start()

        queueHelper
            .beforeExecution() { XCTAssertEqual("no error yet", delegate.lastConnectionError.localizedDescription) }
            .afterExecution()  { XCTAssertEqual("bad connection", delegate.lastConnectionError.localizedDescription) }
    }

    func testConnectionErrorOnWriteIsSentToDelegate() {
        let transport = ControlledInteractionTransport()
        transport.stubbedToThrowErrorOnWrite = "bad write"
        let delegate = ConnectionDelegateSpy()
        let queueHelper = QueueHelper()
        let conn = RMQConnection(
            transport: transport,
            user: "foo",
            password: "bar",
            vhost: "",
            channelMax: 123,
            frameMax: 321,
            heartbeat: 10,
            syncTimeout: 1,
            delegate: delegate,
            delegateQueue: queueHelper.dispatchQueue
        )
        conn.start()

        queueHelper
            .beforeExecution() { XCTAssertEqual("no error yet", delegate.lastConnectionError.localizedDescription) }
            .afterExecution()  { XCTAssertEqual("bad write", delegate.lastConnectionError.localizedDescription) }
    }

    func testTimeoutWhenWaitingForHandshakeToComplete() {
        let transport = ControlledInteractionTransport()
        let delegate = ConnectionDelegateSpy()
        let queueHelper = QueueHelper()
        let conn = RMQConnection(
            transport: transport,
            user: "foo",
            password: "bar",
            vhost: "",
            channelMax: 123,
            frameMax: 321,
            heartbeat: 10,
            syncTimeout: 0,
            delegate: delegate,
            delegateQueue: queueHelper.dispatchQueue
        )
        conn.start()

        queueHelper
            .beforeExecution { XCTAssertEqual("no error yet", delegate.lastConnectionError.localizedDescription) }
            .afterExecution  { XCTAssertEqual("Timed out waiting for AMQConnectionOpenOk", delegate.lastConnectionError.localizedDescription) }
    }

    func testHandshaking() {
        let transport = ControlledInteractionTransport()
        startedConnection(transport)
        transport
            .assertClientSentProtocolHeader()
            .serverSendsPayload(MethodFixtures.connectionStart(), channelNumber: 0)
            .assertClientSentMethod(MethodFixtures.connectionStartOk(), channelNumber: 0)
            .serverSendsPayload(MethodFixtures.connectionTune(), channelNumber: 0)
            .assertClientSentMethods([MethodFixtures.connectionTuneOk(), MethodFixtures.connectionOpen()], channelNumber: 0)
            .serverSendsPayload(MethodFixtures.connectionOpenOk(), channelNumber: 0)
    }

    func testClientInitiatedClosing() {
        let transport = ControlledInteractionTransport()
        let conn = startedConnection(transport)
        transport.handshake()
        conn.close()

        transport.assertClientSentMethod(
            AMQConnectionClose(
                replyCode: AMQShort(200),
                replyText: AMQShortstr("Goodbye"),
                classId: AMQShort(0),
                methodId: AMQShort(0)
            ),
            channelNumber: 0
        )
        XCTAssert(transport.isConnected())
        transport.serverSendsPayload(MethodFixtures.connectionCloseOk(), channelNumber: 0)
        XCTAssertFalse(transport.isConnected())
    }

    func testServerInitiatedClosing() {
        let transport = ControlledInteractionTransport()
        startedConnection(transport)
        transport.handshake()

        XCTAssertTrue(transport.isConnected())
        transport.serverSendsPayload(MethodFixtures.connectionClose(), channelNumber: 0)
        XCTAssertFalse(transport.isConnected())
        transport.assertClientSentMethod(MethodFixtures.connectionCloseOk(), channelNumber: 0)
    }

    func testCreatingAChannelSendsAChannelOpenAndReceivesOpenOK() {
        let transport = ControlledInteractionTransport()
        let conn = startedConnection(transport)

        transport.handshake()

        try! conn.createChannel()

        transport
            .assertClientSentMethod(MethodFixtures.channelOpen(), channelNumber: 1)
            .serverSendsPayload(MethodFixtures.channelOpenOk(), channelNumber: 1)
    }

    func testCreatingAChannelThrowsWhenTransportThrows() {
        let transport = ControlledInteractionTransport()
        let conn = startedConnection(transport)
        transport.stubbedToThrowErrorOnWrite = "stubbed message"

        do {
            try conn.createChannel()
            XCTFail("No error assigned")
        }
        catch let e as NSError {
            XCTAssertEqual("stubbed message", e.localizedDescription)
        }
        catch {
            XCTFail("Wrong error")
        }
    }

    func testWaitingOnServerMessagesWithSuccess() {
        let transport = ControlledInteractionTransport()
        let conn = startedConnection(transport, syncTimeout: 0.4)
        let delay1 = dispatch_time(DISPATCH_TIME_NOW, Int64(0.1 * Double(NSEC_PER_SEC)))
        let delay2 = dispatch_time(DISPATCH_TIME_NOW, Int64(0.2 * Double(NSEC_PER_SEC)))

        let stubbedPayload1 = MethodFixtures.connectionOpenOk()
        dispatch_after(delay1, dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_LOW, 0)) {
            transport.serverSendsPayload(stubbedPayload1, channelNumber: 42)
        }

        let stubbedPayload2 = MethodFixtures.connectionTune()
        dispatch_after(delay2, dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_BACKGROUND, 0)) {
            transport.serverSendsPayload(stubbedPayload2, channelNumber: 56)
        }

        let group = dispatch_group_create()
        let queues      = [
            dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_HIGH, 0),
            dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_LOW, 0),
        ]
        var receivedMethod1: AMQConnectionOpenOk = AMQConnectionOpenOk()
        var receivedMethod2: AMQConnectionTune = AMQConnectionTune()

        dispatch_group_async(group, queues[0]) {
            let receivedFrameset2 = try! conn.sendFrameset(
                AMQFrameset(channelNumber: 56, method: MethodFixtures.connectionStartOk()),
                waitOnMethod: AMQConnectionTune.self
            )
            receivedMethod2 = receivedFrameset2.method as! AMQConnectionTune
        }

        dispatch_group_async(group, queues[1]) {
            let receivedFrameset1 = try! conn.sendFrameset(
                AMQFrameset(channelNumber: 42, method: MethodFixtures.connectionOpen()),
                waitOnMethod: AMQConnectionOpenOk.self
            )
            receivedMethod1 = receivedFrameset1.method as! AMQConnectionOpenOk
        }

        dispatch_group_wait(group, DISPATCH_TIME_FOREVER)

        XCTAssertEqual(stubbedPayload1, receivedMethod1)
        XCTAssertEqual(stubbedPayload2, receivedMethod2)
    }

    func testWaitingOnAServerMethodWithWaitFailure() {
        let transport = ControlledInteractionTransport()
        let conn = startedConnection(transport, syncTimeout: 0.1)

        var error: NSError = NSError(domain: "", code: 0, userInfo: [:])
        do {
            try conn.sendFrameset(
                AMQFrameset(channelNumber: 42, method: MethodFixtures.connectionStartOk()),
                waitOnMethod: AMQConnectionTune.self
            )
        }
        catch let e as NSError {
            error = e
        }
        catch {
            XCTFail("Wrong error")
        }
        XCTAssertEqual("Timed out waiting for AMQConnectionTune", error.localizedDescription)
    }

    func testWaitingOnAServerMethodWithSendFailure() {
        let transport = ControlledInteractionTransport()
        let conn = startedConnection(transport, syncTimeout: 0)
        transport.stubbedToThrowErrorOnWrite = "please fail"

        var error: NSError = NSError(domain: "", code: 0, userInfo: [:])
        do {
            try conn.sendFrameset(
                AMQFrameset(channelNumber: 42, method: MethodFixtures.connectionStartOk()),
                waitOnMethod: AMQConnectionTune.self
            )
        }
        catch let e as NSError {
            error = e
        }
        catch {
            XCTFail("Wrong error")
        }
        XCTAssertEqual("please fail", error.localizedDescription)
    }

}
