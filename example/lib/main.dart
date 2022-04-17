import 'package:flutter/material.dart';
import 'dart:async';

import 'package:zebra_bluetooth_printer/zebra_bluetooth_printer.dart';

void main() {
  runApp(const MyApp());
}

class MyApp extends StatefulWidget {
  const MyApp({Key? key}) : super(key: key);

  @override
  State<MyApp> createState() => _MyAppState();
}

class _MyAppState extends State<MyApp> {

  String printText = 'Unknown';
  var controller = StreamController<String>();
  late Stream<String> stream = controller.stream;
  final ValueNotifier<String> _bluetooth = ValueNotifier<String>("no data");

  @override
  void initState() {
    super.initState();
  }

  // Platform messages are asynchronous, so we initialize in an async method.
  Future<void> initPlatformState() async {
    // Platform messages may fail, so we use a try/catch PlatformException.
    // We also handle the message potentially returning null.
    // try {
      // platformVersion = await ZebraBluetoothPrinter.platformVersion ??
      //     'Unknown platform version';

      // print = await ZebraBluetoothPrinter.print("zpl 1234 ",) ??
      //     'Unknown platform version';
    // } on PlatformException {
    // }

    // If the widget was removed from the tree while the asynchronous platform
    // message was in flight, we want to discard the reply rather than calling
    // setState to update our non-existent appearance.
    // if (!mounted) return;
    //
    // setState(() {
    //   _platformVersion = platformVersion;
    // });
  }

  // ignore: prefer_adjacent_string_concatenation
  String zpl = "^XA" +
      "^MnM^LH150,10" +
      "^CWZ,E:TT0003M_.FNT^FS" +
      "^PA1,1,1,1^FS" //^PA command is mandatory for RTL Languages like Arabic & Hebrew
//                        + "^FT10,40^CI28^AZN,40,40^^FD  اوربا زيبرة  تكنوليجيز اوربا المحدو^FS"
      +
      "^FT10,60^CI28^AZN,40,40^^FD  شيتوس شيبس كاتشب 55غم^FS" +
      "^FS^FPH,3^FT70,260^A0N,115,115^FB460,1,0,R^FH\\^FD 32.53 ^FS^CI27"

//                        + "FO100,220^CI28^AZN,50,40^TBN,500,200^FD-l 35 ^FS"
      +
      "^FO30,185^BY3" +
      "^BY2^BEN,70,Y,N" +
      "^FD7290001817728^FS"
//                        + "^FO0,0^GB480,270,2,B,1^FS"
      +
      "^PQ1" +
      "^XZ";
  int io = 0;
  //  Stream _clock() async* {
  //    // This loop will run forever because _running is always true
  //    while (true) {
  //      await Future<void>.delayed(const Duration(seconds: 1));
  //     DateTime _now = DateTime.now();
  //     // This will be displayed on the screen as current time
  //     yield "${_now.hour} : ${_now.minute} : ${_now.second}";
  //     // yield "$print";
  //   }
  // }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      home: Scaffold(
        appBar: AppBar(
          title: const Text('Plugin example app'),
        ),
        body: Center(
          child: Column(
            children: [
              Text('Running on: $print\n'),
              ElevatedButton(
                onPressed: () async {
                  debugPrint("sdsdsd");

                  ZebraBluetoothPrinter.eventChannel
                      .receiveBroadcastStream()
                      .listen((event) {
                    debugPrint(event);
                    _bluetooth.value = event;
                  });
                  await ZebraBluetoothPrinter.print(zpl, "607771C080BC");
                },
                child: const Text("test"),
              ),
              ValueListenableBuilder(
                valueListenable: _bluetooth,
                builder: (BuildContext context, String value, Widget? child) {
                  return Text("ok :" + _bluetooth.value);
                },
                child: Text("ok :" + _bluetooth.value),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
