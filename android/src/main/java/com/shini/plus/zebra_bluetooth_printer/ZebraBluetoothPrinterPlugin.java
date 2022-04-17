package com.shini.plus.zebra_bluetooth_printer;

import android.app.Activity;

import android.graphics.Color;
import android.util.Log;

import androidx.annotation.NonNull;

import java.util.EventListener;
import java.util.List;
import java.util.logging.Level;

import io.flutter.embedding.engine.plugins.FlutterPlugin;
import io.flutter.plugin.common.EventChannel;
import io.flutter.plugin.common.MethodCall;
import io.flutter.plugin.common.MethodChannel;
import io.flutter.plugin.common.MethodChannel.MethodCallHandler;
import io.flutter.plugin.common.MethodChannel.Result;

import com.zebra.sdk.comm.BluetoothConnection;
import com.zebra.sdk.comm.Connection;
import com.zebra.sdk.comm.ConnectionException;
import com.zebra.sdk.comm.TcpConnection;
import com.zebra.sdk.printer.PrinterLanguage;
import com.zebra.sdk.printer.PrinterStatus;
import com.zebra.sdk.printer.SGD;
import com.zebra.sdk.printer.ZebraPrinter;
import com.zebra.sdk.printer.ZebraPrinterFactory;
import com.zebra.sdk.printer.ZebraPrinterLanguageUnknownException;
import com.zebra.sdk.printer.ZebraPrinterLinkOs;

/**
 * ZebraBluetoothPrinterPlugin
 */
public class ZebraBluetoothPrinterPlugin implements FlutterPlugin, MethodCallHandler, EventChannel.StreamHandler {
    /// The MethodChannel that will the communication between Flutter and native Android
    ///
    /// This local reference serves to register the plugin with the Flutter Engine and unregister it
    /// when the Flutter Engine is detached from the Activity
    private MethodChannel channel;
    private EventChannel.EventSink eventSink;
    private Connection connection;
    private ZebraPrinter printer;

    @Override
    public void onAttachedToEngine(@NonNull FlutterPluginBinding flutterPluginBinding) {
        channel = new MethodChannel(flutterPluginBinding.getBinaryMessenger(), "zebra_bluetooth_printer");
        channel.setMethodCallHandler(this);
        EventChannel eventChannel = new EventChannel(flutterPluginBinding.getBinaryMessenger(), "zebra_bluetooth_printer_stream");
        eventChannel.setStreamHandler(this);
    }

    @Override
    public void onMethodCall(@NonNull MethodCall call, @NonNull Result result) {
        switch (call.method) {
            case "getPlatformVersion":
                result.success(android.os.Build.VERSION.RELEASE);
                break;
            case "connect":


                if (!(connection != null && connection.isConnected())) {
                    printer = connect(call.arguments());
                }
                if (connection.isConnected() && printer != null) {
                    result.success(true);
                } else {
                    disconnect();
                    result.success(false);
                }
                break;
            case "disconnect":

                disconnect();
                result.success(true);
                break;
            case "print":
                List<Object> arg;
                arg = call.arguments();
//                if (printer == null||!(connection != null && connection.isConnected())) {
//                    printer = connect((String) arg.get(1));
//                }

                if (!(connection != null && connection.isConnected())) {
                    printer = connect((String) arg.get(1));
                }
                if (connection.isConnected() && printer != null) {
                    result.success(sendTestLabel((String) arg.get(0)));
                } else {
//                    disconnect();
                    result.success(false);
                }
                break;
            default:
                result.notImplemented();
                break;
        }
    }

    @Override
    public void onDetachedFromEngine(@NonNull FlutterPluginBinding binding) {
        channel.setMethodCallHandler(null);
    }


    @Override
    public void onCancel(Object arguments) {
        eventSink = null;
    }

    @Override
    public void onListen(Object arguments, EventChannel.EventSink events) {
        eventSink = events;

    }

    public ZebraPrinter connect(String macAddress) {
        Log.i("connect", "Connecting...");
        connection = null;
        connection = new BluetoothConnection(macAddress);


        try {
            connection.open();
//            Log.i("connection.open", "Connected ");
        } catch (ConnectionException e) {
            if (eventSink != null)
                eventSink.success("Comm Error! Disconnecting");
//            Log.i("ConnectionException", "Comm Error! Disconnecting");

            disconnect();
        }

        ZebraPrinter printer = null;

        if (connection.isConnected()) {
            try {

                printer = ZebraPrinterFactory.getInstance(connection);

//                Log.i("connect", "Determining Printer Language");

//                Log.i("connect", "Printer Language" + pl);
            } catch (ConnectionException | ZebraPrinterLanguageUnknownException e) {

                Log.i("connect", "Unknown Printer Language");
                printer = null;

                disconnect();
            }
        }

        return printer;
    }

    public void disconnect() {
        try {

//            Log.i("disconnect", "Disconnecting");
            if (connection != null) {
                connection.close();
                printer = null;
            }

//            Log.i("disconnect", "Not Connected");
        } catch (ConnectionException e) {
            if (eventSink != null)
                eventSink.success("COMM Error! Disconnected");
//            Log.i("disconnect", "COMM Error! Disconnected");
        } finally {
//            enableTestButton(true);
        }
    }

    private boolean sendTestLabel(String zpl) {
        try {
            ZebraPrinterLinkOs linkOsPrinter = ZebraPrinterFactory.createLinkOsPrinter(printer);

            PrinterStatus printerStatus = (linkOsPrinter != null) ? linkOsPrinter.getCurrentStatus() : printer.getCurrentStatus();

            if (printerStatus.isReadyToPrint) {
                byte[] configLabel = getConfigLabel(zpl);
                connection.write(configLabel);
                if (eventSink != null)
                    eventSink.success("Sending Data");
                return true;
//                Log.i("sendTestLabel", "Sending Data");
            } else if (printerStatus.isHeadOpen) {
                if (eventSink != null)
                    eventSink.success("Printer Head Open");

//                Log.i("sendTestLabel", "Printer Head Open");
            } else if (printerStatus.isPaused) {
                if (eventSink != null)
                    eventSink.success("Printer is Paused");
//                Log.i("sendTestLabel", "Printer is Paused");

            } else if (printerStatus.isPaperOut) {
                if (eventSink != null)
                    if (eventSink != null)
                        eventSink.success("Printer Media Out");
//                Log.i("sendTestLabel", "Printer Media Out");

            }

            if (connection instanceof BluetoothConnection) {
                String friendlyName = ((BluetoothConnection) connection).getFriendlyName();
                if (eventSink != null)
                    eventSink.success(friendlyName);
//                Log.i("sendTestLabel", "friendlyName");

            }
        } catch (ConnectionException e) {
            if (eventSink != null)
                eventSink.success(e.getMessage());

        }
        return false;
    }

    private byte[] getConfigLabel(String zpl) {
        byte[] configLabel = null;
        try {
            PrinterLanguage printerLanguage = printer.getPrinterControlLanguage();
            SGD.SET("device.languages", "zpl", connection);


            if (printerLanguage == PrinterLanguage.ZPL) {

                //para configurar un formato de impresion diseñarlo en la siguiente pagina http://labelary.com/viewer.html

//                String bytes = "^XA^FX Top section with company logo, name and address.^CF0,60^FO50,50^GB100,100,100^FS^FO75,75^FR^GB100,100,100^FS^FO88,88^GB50,50,50^FS^FO220,50^FDIntershipping, Inc.^FS^CF0,30^FO220,115^FD1000 Shipping Lane^FS^FO220,155^FDShelbyville TN 38102^FS^FO220,195^FDUnited States (USA)^FS^FO50,250^GB700,1,3^FS^FX Second section with recipient address and permit information.^CFA,30^FO50,300^FDJohn Doe^FS^FO50,340^FD100 Main Street^FS^FO50,380^FDSpringfield TN 39021^FS^FO50,420^FDUnited States (USA)^FS^CFA,15^FO600,300^GB150,150,3^FS^FO638,340^FDPermit^FS^FO638,390^FD123456^FS^FO50,500^GB700,1,3^FS^FX Third section with barcode.^BY5,2,270^FO100,550^BC^FD12345678^FS^FX Fourth section (the two boxes on the bottom).^FO50,900^GB700,250,3^FS^FO400,900^GB1,250,3^FS^CF0,40^FO100,960^FDCtr. X34B-1^FS^FO100,1010^FDREF1 F00B47^FS^FO100,1060^FDREF2 BL4H8^FS^CF0,190^FO470,955^FDCA^FS^XZ";
//                String bytes = "^XA^FO120,20^A0N,25,25^FDThis is a ZPL test.^FS^FPH,3^FT225,224^A@N,35,35,TT0003M_^FH\\^CI28^FD Akrak اكرم^FS^CI27\n ^XZ";
                String text = " مح1كمة مح1كمة مح1كمة مح1كمة مح1كمة ملاكمة";

//                String bytes = "^XA^LRN^CI0^XZ" +
//
//                        "^XA^CWZ,E:TT0003M_.FNT^FS^XZ" +
//                        "^XA" +
//
////                        "^FS^FPH,3^FT10,30^A@N,35,35,TT0003M_.FNT^FH\\\\^CI28^FD" + text + "^FS^CI27" +
//                        "^FS^FPH,3^A@N,35,35,TT0003M_.FNT^TBN,600,100^FH\\\\^CI28^FD Ak" + text + " ^FS^CI27" +
////                       "^FS^FPH,3^FT10,00^A@N,35,35,TT0003M_.FNT^FB480,2,3,C^FH\\\\^CI28^FD 36 dfdf dffd dfdf f fdfdf dfdf ^FS^CI27"+
////                        "^FT70,80^A0B,28,28^FB500,2,3,C^FH\\^FDTEXT_TO_REPLACE^FS"+
//                        "^PQ1" +
//                        "^FO0,0^GB500,280,2,B,1^FS" +
//                        "^XZ";

                configLabel = zpl.getBytes();

            } else if (printerLanguage == PrinterLanguage.CPCL) {
                String cpclConfigLabel = "! 0 200 200 406 1\r\n" + "ON-FEED IGNORE\r\n" + "BOX 20 20 380 380 8\r\n" + "T 0 6 137 177 TEST\r\n" + "PRINT\r\n";
                configLabel = cpclConfigLabel.getBytes();
            }
        } catch (ConnectionException e) {
            Log.e("ConectionExeption", e.getMessage() + " " + e.getCause());
        }
        return configLabel;
    }

}
