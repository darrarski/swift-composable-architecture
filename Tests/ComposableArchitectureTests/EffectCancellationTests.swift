import Combine
import XCTest

@testable import ComposableArchitecture

final class EffectCancellationTests: XCTestCase {
  struct CancelToken: Hashable {}
  var cancellables: Set<AnyCancellable> = []

  override func tearDown() {
    super.tearDown()
    self.cancellables.removeAll()
  }

  func testCancellation() {
    var values: [Int] = []

    let subject = PassthroughSubject<Int, Never>()
    let effect = Effect(subject)
      .cancellable(id: CancelToken())

    effect
      .sink { values.append($0) }
      .store(in: &self.cancellables)

    XCTAssertEqual(values, [])
    subject.send(1)
    XCTAssertEqual(values, [1])
    subject.send(2)
    XCTAssertEqual(values, [1, 2])

    _ = Effect<Never, Never>.cancel(id: CancelToken())
      .sink { _ in }
      .store(in: &self.cancellables)

    subject.send(3)
    XCTAssertEqual(values, [1, 2])
  }

  func testCancelInFlight() {
    var values: [Int] = []

    let subject = PassthroughSubject<Int, Never>()
    Effect(subject)
      .cancellable(id: CancelToken(), cancelInFlight: true)
      .sink { values.append($0) }
      .store(in: &self.cancellables)

    XCTAssertEqual(values, [])
    subject.send(1)
    XCTAssertEqual(values, [1])
    subject.send(2)
    XCTAssertEqual(values, [1, 2])

    Effect(subject)
      .cancellable(id: CancelToken(), cancelInFlight: true)
      .sink { values.append($0) }
      .store(in: &self.cancellables)

    subject.send(3)
    XCTAssertEqual(values, [1, 2, 3])
    subject.send(4)
    XCTAssertEqual(values, [1, 2, 3, 4])
  }

  func testCancellationAfterDelay() {
    var value: Int?

    Just(1)
      .delay(for: 0.15, scheduler: DispatchQueue.main)
      .eraseToEffect()
      .cancellable(id: CancelToken())
      .sink { value = $0 }
      .store(in: &self.cancellables)

    XCTAssertEqual(value, nil)

    DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
      _ = Effect<Never, Never>.cancel(id: CancelToken())
        .sink { _ in }
        .store(in: &self.cancellables)
    }

    _ = XCTWaiter.wait(for: [self.expectation(description: "")], timeout: 0.3)

    XCTAssertEqual(value, nil)
  }

  func testCancellationAfterDelay_WithTestScheduler() {
    let scheduler = DispatchQueue.testScheduler
    var value: Int?

    Just(1)
      .delay(for: 2, scheduler: scheduler)
      .eraseToEffect()
      .cancellable(id: CancelToken())
      .sink { value = $0 }
      .store(in: &self.cancellables)

    XCTAssertEqual(value, nil)

    scheduler.advance(by: 1)
    Effect<Never, Never>.cancel(id: CancelToken())
      .sink { _ in }
      .store(in: &self.cancellables)

    scheduler.run()

    XCTAssertEqual(value, nil)
  }

  func testCancellablesCleanUp_OnComplete() {
    Just(1)
      .eraseToEffect()
      .cancellable(id: 1)
      .sink(receiveValue: { _ in })
      .store(in: &self.cancellables)

    XCTAssertEqual([:], cancellationCancellables)
  }

  func testCancellablesCleanUp_OnCancel() {
    let scheduler = DispatchQueue.testScheduler
    Just(1)
      .delay(for: 1, scheduler: scheduler)
      .eraseToEffect()
      .cancellable(id: 1)
      .sink(receiveValue: { _ in })
      .store(in: &self.cancellables)

    Effect<Int, Never>.cancel(id: 1)
      .sink(receiveValue: { _ in })
      .store(in: &self.cancellables)

    XCTAssertEqual([:], cancellationCancellables)
  }

  func testDoubleCancellation() {
    var values: [Int] = []

    let subject = PassthroughSubject<Int, Never>()
    let effect = Effect(subject)
      .cancellable(id: CancelToken())
      .cancellable(id: CancelToken())

    effect
      .sink { values.append($0) }
      .store(in: &self.cancellables)

    XCTAssertEqual(values, [])
    subject.send(1)
    XCTAssertEqual(values, [1])

    _ = Effect<Never, Never>.cancel(id: CancelToken())
      .sink { _ in }
      .store(in: &self.cancellables)

    subject.send(2)
    XCTAssertEqual(values, [1])
  }

  func testCompleteBeforeCancellation() {
    var values: [Int] = []

    let subject = PassthroughSubject<Int, Never>()
    let effect = Effect(subject)
      .cancellable(id: CancelToken())

    effect
      .sink { values.append($0) }
      .store(in: &self.cancellables)

    subject.send(1)
    XCTAssertEqual(values, [1])

    subject.send(completion: .finished)
    XCTAssertEqual(values, [1])

    _ = Effect<Never, Never>.cancel(id: CancelToken())
      .sink { _ in }
      .store(in: &self.cancellables)

    XCTAssertEqual(values, [1])
  }

  func testConcurrentCancels() {
    let queues = [
      DispatchQueue.main,
      DispatchQueue.global(qos: .background),
      DispatchQueue.global(qos: .default),
      DispatchQueue.global(qos: .unspecified),
      DispatchQueue.global(qos: .userInitiated),
      DispatchQueue.global(qos: .userInteractive),
      DispatchQueue.global(qos: .utility),
    ]

    let effect = Effect.merge(
      (1...1_000).map { idx -> Effect<Int, Never> in
        let id = idx % 10

        return Effect.merge(
          Just(idx)
            .delay(
              for: .milliseconds(Int.random(in: 1...100)), scheduler: queues.randomElement()!
            )
            .eraseToEffect()
            .cancellable(id: id),

          Just(())
            .delay(
              for: .milliseconds(Int.random(in: 1...100)), scheduler: queues.randomElement()!
            )
            .flatMap { Effect.cancel(id: id) }
            .eraseToEffect()
        )
      }
    )

    let expectation = self.expectation(description: "wait")
    effect
      .sink(receiveCompletion: { _ in expectation.fulfill() }, receiveValue: { _ in })
      .store(in: &self.cancellables)
    self.wait(for: [expectation], timeout: 999)

    XCTAssertTrue(cancellationCancellables.isEmpty)
  }

  func testNestedCancels() {
    var effect = Empty<Void, Never>(completeImmediately: false)
      .eraseToEffect()
      .cancellable(id: 1)

    for _ in 1 ... .random(in: 1...1_000) {
      effect = effect.cancellable(id: 1)
    }

    effect
      .sink(receiveValue: { _ in })
      .store(in: &cancellables)

    cancellables.removeAll()

    XCTAssertEqual([:], cancellationCancellables)
  }

  func testSharedId() {
    let scheduler = DispatchQueue.testScheduler

    let effect1 = Just(1)
      .delay(for: 1, scheduler: scheduler)
      .eraseToEffect()
      .cancellable(id: "id")

    let effect2 = Just(2)
      .delay(for: 2, scheduler: scheduler)
      .eraseToEffect()
      .cancellable(id: "id")

    var expectedOutput: [Int] = []
    effect1
      .sink { expectedOutput.append($0) }
      .store(in: &cancellables)
    effect2
      .sink { expectedOutput.append($0) }
      .store(in: &cancellables)

    XCTAssertEqual(expectedOutput, [])
    scheduler.advance(by: 1)
    XCTAssertEqual(expectedOutput, [1])
    scheduler.advance(by: 1)
    XCTAssertEqual(expectedOutput, [1, 2])
  }

  func testImmediateCancellation() {
    let scheduler = DispatchQueue.testScheduler

    var expectedOutput: [Int] = []
    // Don't hold onto cancellable so that it is deallocated immediately.
    _ = Deferred { Just(1) }
      .delay(for: 1, scheduler: scheduler)
      .eraseToEffect()
      .cancellable(id: "id")
      .sink { expectedOutput.append($0) }

    XCTAssertEqual(expectedOutput, [])
    scheduler.advance(by: 1)
    XCTAssertEqual(expectedOutput, [])
  }

  /// Custom Combine Publisher, used in the following tests
  class CustomPublisher: Publisher {
    typealias Output = Void
    typealias Failure = Never

    func receive<S>(subscriber: S) where S: Subscriber, S.Failure == Failure, S.Input == Output {}
  }

  /// Check if CustomPublisher is correctly released from the memory after cancelling the subscription
  func testCustomPublisherRelease() {
    var publisher: CustomPublisher!
    weak var weakPublisher: CustomPublisher?
    var receivedRequests = 0
    var receivedCancels = 0
    var cancellables = Set<AnyCancellable>()

    publisher = CustomPublisher()
    weakPublisher = publisher
    publisher.handleEvents(
      receiveCancel: { receivedCancels += 1 },
      receiveRequest: { _ in receivedRequests += 1 })
      .sink(receiveValue: { _ in })
      .store(in: &cancellables)

    XCTAssertNotNil(weakPublisher)

    publisher = nil

    XCTAssertNotNil(weakPublisher)
    XCTAssertEqual(receivedRequests, 1)
    XCTAssertEqual(receivedCancels, 0)

    cancellables.removeAll()

    XCTAssertNil(weakPublisher)
    XCTAssertEqual(receivedRequests, 1)
    XCTAssertEqual(receivedCancels, 1)
  }

  /// Check if CustomPublisher is correctly released from the memory after cancelling an Effect originating from it
  func testEffectCancellationPublisherRelease() {
    struct State: Equatable {}

    enum Action: Equatable {
      case start
      case stop
      case action
    }

    var store: TestStore<State, State, Action, Action, Void>!
    var reducer: Reducer<State, Action, Void>!
    weak var weakPublisher: CustomPublisher?
    var receivedRequests = 0
    var receivedCancels = 0

    reducer = Reducer { state, action, _ in
      struct EffectId: Hashable {}

      switch action {
      case .start:
        let publisher = CustomPublisher()
        weakPublisher = publisher
        return publisher
          .handleEvents(receiveCancel: {
            receivedCancels += 1
          }, receiveRequest: { _ in
            receivedRequests += 1
          })
          .map { Action.action }
          .eraseToEffect()
          .cancellable(id: EffectId(), cancelInFlight: true)

      case .stop:
        return .cancel(id: EffectId())

      case .action:
        return .none
      }
    }

    store = TestStore(
      initialState: State(),
      reducer: reducer,
      environment: ()
    )

    store.assert(
      .do {
        XCTAssertNil(weakPublisher)
        XCTAssertEqual(receivedRequests, 0)
        XCTAssertEqual(receivedCancels, 0)
      },
      .send(.start),
      .do {
        XCTAssertNotNil(weakPublisher)
        XCTAssertEqual(receivedRequests, 1)
        XCTAssertEqual(receivedCancels, 0)
      },
      .send(.stop),
      .do {
        XCTAssertNil(weakPublisher)
        XCTAssertEqual(receivedRequests, 1)
        XCTAssertEqual(receivedCancels, 1)
      }
    )

    store = nil
    reducer = nil
    XCTAssertNil(weakPublisher)
    XCTAssertEqual(receivedRequests, 1)
    XCTAssertEqual(receivedCancels, 1)
  }
}
