import 'package:test/test.dart';
import 'package:dart_cast/dart_cast.dart';

void main() {
  group('SessionState', () {
    test('has all expected values', () {
      expect(
        SessionState.values,
        containsAll([
          SessionState.connecting,
          SessionState.connected,
          SessionState.loading,
          SessionState.playing,
          SessionState.paused,
          SessionState.buffering,
          SessionState.idle,
          SessionState.disconnected,
        ]),
      );
    });
  });

  group('SessionStateMachine', () {
    late SessionStateMachine sm;

    setUp(() {
      sm = SessionStateMachine();
    });

    tearDown(() {
      sm.dispose();
    });

    test('starts in disconnected state', () {
      expect(sm.state, SessionState.disconnected);
    });

    test('valid transitions through full lifecycle', () {
      sm.transitionTo(SessionState.connecting);
      expect(sm.state, SessionState.connecting);

      sm.transitionTo(SessionState.connected);
      expect(sm.state, SessionState.connected);

      sm.transitionTo(SessionState.loading);
      expect(sm.state, SessionState.loading);

      sm.transitionTo(SessionState.playing);
      expect(sm.state, SessionState.playing);

      sm.transitionTo(SessionState.paused);
      expect(sm.state, SessionState.paused);

      sm.transitionTo(SessionState.playing);
      expect(sm.state, SessionState.playing);

      sm.transitionTo(SessionState.buffering);
      expect(sm.state, SessionState.buffering);

      sm.transitionTo(SessionState.playing);
      expect(sm.state, SessionState.playing);

      sm.transitionTo(SessionState.idle);
      expect(sm.state, SessionState.idle);

      sm.transitionTo(SessionState.disconnected);
      expect(sm.state, SessionState.disconnected);
    });

    test('any state can transition to disconnected', () {
      for (final state in SessionState.values) {
        final machine = SessionStateMachine();
        machine.forceState(state);
        machine.transitionTo(SessionState.disconnected);
        expect(machine.state, SessionState.disconnected);
        machine.dispose();
      }
    });

    test('invalid transition throws StateError', () {
      // disconnected -> playing is not valid
      expect(() => sm.transitionTo(SessionState.playing), throwsStateError);
    });

    test('canTransitionTo returns correct bool', () {
      expect(sm.canTransitionTo(SessionState.connecting), isTrue);
      expect(sm.canTransitionTo(SessionState.playing), isFalse);
      expect(sm.canTransitionTo(SessionState.disconnected), isTrue);
    });

    test('stateStream emits state changes', () async {
      final states = <SessionState>[];
      final sub = sm.stateStream.listen(states.add);

      sm.transitionTo(SessionState.connecting);
      sm.transitionTo(SessionState.connected);
      sm.transitionTo(SessionState.disconnected);

      await Future<void>.delayed(Duration.zero);

      expect(states, [
        SessionState.connecting,
        SessionState.connected,
        SessionState.disconnected,
      ]);

      await sub.cancel();
    });

    test('forceState sets state without validation', () {
      sm.forceState(SessionState.playing);
      expect(sm.state, SessionState.playing);
    });
  });
}
