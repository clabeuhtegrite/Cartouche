//
//  CartoucheGamepad.swift
//  Cartouche
//
//  A game controller drives the home screen as it would a console's: the
//  D-pad or the left stick moves between games, A plays, B goes back, X
//  opens the game's sheet, Y the list of every game, Menu the system page,
//  and the shoulder buttons change the list's filter. A held direction
//  repeats. Touch keeps working alongside.
//
//  A game takes over the controller once it starts: LiveContainer runs it
//  in place of the launcher.
//

import Combine
import GameController

@available(iOS 17.0, *)
@MainActor
final class CartoucheGamepad: ObservableObject {
    enum Input: Hashable {
        case up, down, left, right
        case a, b, x, y, menu
        case previous, next
    }

    static let shared = CartoucheGamepad()

    /// Whether a controller with a D-pad and face buttons is connected, so
    /// that the screen shows which button does what.
    @Published private(set) var isConnected = false

    /// Each press once; a held direction repeats.
    let inputs = PassthroughSubject<Input, Never>()

    private var held: Input?
    private var repeating: Task<Void, Never>?
    private var observers: [NSObjectProtocol] = []

    private init() {
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: .GCControllerDidConnect, object: nil, queue: .main) { [weak self] note in
            let controller = note.object as? GCController
            MainActor.assumeIsolated { self?.attach(controller) }
        })
        observers.append(center.addObserver(forName: .GCControllerDidDisconnect, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.update() }
        })
        for controller in GCController.controllers() {
            attach(controller)
        }
        update()
    }

    /// Shows the button hints without a controller (the launcher's
    /// screenshots).
    func showHints() {
        isConnected = true
    }

    /// The symbol of a button as the connected controller marks it (a
    /// letter on one, a shape on another), or a letter without one.
    func symbol(for input: Input) -> String {
        let pad = (GCController.current ?? GCController.controllers().first)?.extendedGamepad
        switch input {
        case .a: return pad?.buttonA.sfSymbolsName ?? "a.circle.fill"
        case .b: return pad?.buttonB.sfSymbolsName ?? "b.circle.fill"
        case .x: return pad?.buttonX.sfSymbolsName ?? "x.circle.fill"
        case .y: return pad?.buttonY.sfSymbolsName ?? "y.circle.fill"
        case .menu: return pad?.buttonMenu.sfSymbolsName ?? "line.3.horizontal.circle.fill"
        case .previous: return pad?.leftShoulder.sfSymbolsName ?? "l1.rectangle.roundedbottom.fill"
        case .next: return pad?.rightShoulder.sfSymbolsName ?? "r1.rectangle.roundedbottom.fill"
        case .up, .down, .left, .right: return pad?.dpad.sfSymbolsName ?? "dpad.fill"
        }
    }

    private func update() {
        isConnected = GCController.controllers().contains { $0.extendedGamepad != nil }
        if !isConnected {
            held = nil
            repeating?.cancel()
        }
    }

    private func attach(_ controller: GCController?) {
        defer { update() }
        guard let controller, let pad = controller.extendedGamepad else { return }
        // Handlers run on the controller's handler queue, the main queue
        // unless someone changes it.
        controller.handlerQueue = .main

        pad.dpad.valueChangedHandler = { [weak self] _, x, y in
            MainActor.assumeIsolated { self?.direction(x: x, y: y) }
        }
        pad.leftThumbstick.valueChangedHandler = { [weak self] _, x, y in
            MainActor.assumeIsolated { self?.direction(x: x, y: y) }
        }
        let buttons: [(GCControllerButtonInput?, Input)] = [
            (pad.buttonA, .a), (pad.buttonB, .b), (pad.buttonX, .x), (pad.buttonY, .y),
            (pad.buttonMenu, .menu), (pad.leftShoulder, .previous), (pad.rightShoulder, .next),
        ]
        for (button, input) in buttons {
            button?.pressedChangedHandler = { [weak self] _, _, pressed in
                guard pressed else { return }
                MainActor.assumeIsolated { self?.inputs.send(input) }
            }
        }
    }

    /// A direction from the D-pad or the stick, past half its travel.
    private func direction(x: Float, y: Float) {
        let input: Input?
        if abs(x) >= abs(y) {
            input = x > 0.5 ? .right : (x < -0.5 ? .left : nil)
        } else {
            input = y > 0.5 ? .up : (y < -0.5 ? .down : nil)
        }
        guard input != held else { return }
        held = input
        repeating?.cancel()
        guard let input else { return }
        inputs.send(input)
        repeating = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(380))
            while !Task.isCancelled {
                self?.inputs.send(input)
                try? await Task.sleep(for: .milliseconds(110))
            }
        }
    }
}
