import '../../services/avatar_message_service.dart';
import '../assistant/state/assistant_engine.dart';
import 'photo_source_sheet.dart';
import 'poster_controller.dart';
import 'poster_device_actions.dart';
import 'poster_screen.dart';
import 'signature/signature_model.dart';
import 'signature/signature_pad.dart';

/// The assistant engine as the card actions' host: its [SYSTEM] line, its
/// microphone hold, and the app's root navigator for the picker, the pad
/// and the card screen.
class EnginePosterHost implements PosterHost {
  EnginePosterHost(this.engine);
  final AssistantEngine engine;

  @override
  Future<void> tellModel(String line) => engine.tellModel(line);

  @override
  Future<T> holdMic<T>(Future<T> Function() body) => engine.holdMicDuring(body);

  @override
  void showPoster() {
    if (engine.onShowPoster?.call() ?? false) return;
    PosterNav.show();
  }

  @override
  Future<PickedPhoto?> pickPhoto(String source) async {
    final ctx = AvatarMessageService.navigatorKey.currentContext;
    if (ctx == null) return null;
    return PhotoSourceSheet.pick(ctx, source);
  }

  @override
  Future<SignatureData?> openSignaturePad() async {
    final ctx = AvatarMessageService.navigatorKey.currentContext;
    if (ctx == null) return null;
    return SignaturePadScreen.open(ctx);
  }
}
