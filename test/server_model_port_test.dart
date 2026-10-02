// THE MODEL BEHIND OUR SERVER (2026-10-02): the request leaves in Gemini's
// wire shape, the server-sent chunks come back as the SDK's own objects,
// and the port is chosen by the served provider.
import 'dart:convert';

import 'package:firebase_ai/firebase_ai.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:myassistant/ai/config.dart';
import 'package:myassistant/ai/model_port.dart';
import 'package:myassistant/ai/server_model_port.dart';

void main() {
  test('the request is Gemini-shaped: contents, system, tools, generation config', () {
    final json = ServerModelPort.requestJson(ModelRequest(
      model: 'gpt-4.1-mini',
      system: 'be brief',
      contents: [Content.text('hello')],
      tools: [Tool.functionDeclarations([FunctionDeclaration('set_timer', 'd', parameters: {'minutes': Schema.integer()})])],
      generationConfig: GenerationConfig(responseMimeType: 'application/json'),
    ));
    expect(json['model'], 'models/gpt-4.1-mini');
    expect((json['contents'] as List).length, 1);
    expect((json['systemInstruction'] as Map)['parts'], isNotEmpty);
    expect(((json['tools'] as List).first as Map)['functionDeclarations'], isNotEmpty);
    expect((json['generationConfig'] as Map)['responseMimeType'], 'application/json');
  });

  test('server-sent chunks become responses: text, a tool call, audio', () async {
    final lines = [
      'data: {"candidates":[{"content":{"role":"model","parts":[{"text":"Hel"}]},"index":0}]}',
      'data: {"candidates":[{"content":{"role":"model","parts":[{"text":"lo"}]},"index":0}]}',
      'data: {"candidates":[{"content":{"role":"model","parts":[{"functionCall":{"name":"set_timer","args":{"minutes":5},"id":"c1"}}]},"finishReason":"STOP","index":0}]}',
      'data: {"candidates":[{"content":{"role":"model","parts":[{"inlineData":{"mimeType":"audio/pcm;rate=24000","data":"${base64Encode(List.filled(48, 7))}"}}]},"index":0}]}',
      'data: [DONE]',
      '',
    ].join('\n');
    late http.BaseRequest seen;
    final client = MockClient.streaming((request, bodyStream) async {
      seen = request;
      await bodyStream.drain<void>();
      return http.StreamedResponse(Stream.value(utf8.encode(lines)), 200);
    });
    final port = ServerModelPort(client: client, baseUrl: () => 'http://x', headers: () => {'Authorization': 'Bearer t'});
    final out = await port.stream(ModelRequest(model: 'm', contents: [Content.text('hi')])).toList();
    expect(seen.url.toString(), 'http://x/ai/generate');
    expect(seen.headers['Authorization'], 'Bearer t');
    expect(seen.headers['Accept'], 'text/event-stream');
    expect(out.length, 4);
    expect(out[0].text, 'Hel');
    expect(out[1].text, 'lo');
    final call = out[2].functionCalls.single;
    expect(call.name, 'set_timer');
    expect(call.args, {'minutes': 5});
    expect(call.id, 'c1');
    expect(out[2].candidates.first.finishReason, FinishReason.stop);
    final audio = out[3].inlineDataParts.single;
    expect(audio.mimeType, 'audio/pcm;rate=24000');
    expect(audio.bytes.length, 48);
  });

  test('an error chunk or a bad status is an exception, never an empty reply', () async {
    final client = MockClient.streaming((request, bodyStream) async {
      await bodyStream.drain<void>();
      return http.StreamedResponse(Stream.value(utf8.encode('data: {"error":{"message":"quota"}}\n')), 200);
    });
    final port = ServerModelPort(client: client, baseUrl: () => 'http://x', headers: () => {});
    expect(port.stream(ModelRequest(model: 'm', contents: [Content.text('hi')])).toList(), throwsA(isA<ServerModelException>()));
    final bad = MockClient((request) async => http.Response('{"error":"no"}', 502));
    final port2 = ServerModelPort(client: bad, baseUrl: () => 'http://x', headers: () => {});
    expect(port2.generate(ModelRequest(model: 'm', contents: [Content.text('hi')])), throwsA(isA<ServerModelException>()));
  });

  test('the served provider decides the port', () {
    expect(AiConfig.fromJson({'provider': 'openai'}).viaServer, isTrue);
    expect(AiConfig.fromJson({}).viaServer, isFalse);
    expect(AiConfig.defaults.viaServer, isFalse);
    expect(ModelPorts.cloud(), isA<ModelPort>());
  });
}
