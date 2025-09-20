package com.shini.plus.zebra_bluetooth_printer;


import android.content.Context;
import androidx.annotation.NonNull;

import java.io.File;
import java.util.List;
import java.util.Objects;

import io.flutter.embedding.engine.plugins.FlutterPlugin;
import io.flutter.plugin.common.EventChannel;
import io.flutter.plugin.common.MethodCall;
import io.flutter.plugin.common.MethodChannel;
import io.flutter.plugin.common.MethodChannel.MethodCallHandler;
import io.flutter.plugin.common.MethodChannel.Result;

import com.shini.plus.zebra_bluetooth_printer.exception.*;
import com.shini.plus.zebra_bluetooth_printer.services.PDfPrintService;
import com.shini.plus.zebra_bluetooth_printer.services.ZPLPrintServices;
import com.zebra.sdk.comm.BluetoothConnection;
import com.zebra.sdk.comm.Connection;
import com.zebra.sdk.comm.ConnectionException;
import com.zebra.sdk.printer.ZebraPrinter;
import com.zebra.sdk.printer.ZebraPrinterFactory;
import com.zebra.sdk.printer.ZebraPrinterLanguageUnknownException;

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
    private Context context;
    String tag = "ZebraBluetoothPrinterPlugin";

    @Override
    public void onAttachedToEngine(@NonNull FlutterPluginBinding flutterPluginBinding) {
        context = flutterPluginBinding.getApplicationContext();
        channel = new MethodChannel(flutterPluginBinding.getBinaryMessenger(), "zebra_bluetooth_printer");
        channel.setMethodCallHandler(this);
        EventChannel eventChannel = new EventChannel(flutterPluginBinding.getBinaryMessenger(), "zebra_bluetooth_printer_stream");
        eventChannel.setStreamHandler(this);
    }

    @Override
    public void onDetachedFromEngine(@NonNull FlutterPluginBinding binding) {
        channel.setMethodCallHandler(null);
    }


    @Override
    public void onCancel(Object arguments) {
        setEventSink(null);
    }

    @Override
    public void onListen(Object arguments, EventChannel.EventSink events) {
        setEventSink(events);
    }

    @Override
    public void onMethodCall(@NonNull MethodCall call, @NonNull Result result) {

        switch (call.method) {

            case MethodChannels.GET_PLATFORM_VERSION:
                result.success(android.os.Build.VERSION.RELEASE);
                break;
            case MethodChannels.CONNECT:

                if (isPrinterNotConnected()) {
                    printer = connect(call.arguments());
                }
                if (connection.isConnected() && printer != null) {
                    result.success(true);
                } else {
                    disconnect();
                    result.success(false);
                }
                break;
            case MethodChannels.DISCONNECT:
                disconnect();
                result.success(true);
                break;
            case MethodChannels.PRINT_ZPL:
                List<String> arg;
                arg = call.arguments();
                assert (Objects.requireNonNull(arg).size() == 2);
                printZPL(arg.get(0), arg.get(1), result);
                break;
            case MethodChannels.PRINT_PDF:
                List<String> argPdf;
                argPdf = call.arguments();
                assert (Objects.requireNonNull(argPdf).size() == 2);
                printPDF(argPdf.get(0), argPdf.get(1), result);
                break;
            case MethodChannels.PRINT_PDF_BYTES:
                List<Object> argPdfBytes;
                argPdfBytes = call.arguments();
                assert (Objects.requireNonNull(argPdfBytes).size() == 2);
                printPDFBytes((String) argPdfBytes.get(0), (byte[]) argPdfBytes.get(1), result);
                break;
            default:
                result.notImplemented();
                break;
        }
    }

    private void printZPL(String macAddress, String zpl, Result result) {

        if (isPrinterNotConnected()) {
            printer = connect(macAddress);
        }

        if (connection.isConnected() && printer != null) {

            ZPLPrintServices printZPLServices = new ZPLPrintServices(connection, printer);


            try {
                result.success(printZPLServices.print(zpl));
            } catch (HeadOpenException | PaperOutException | SendDataException e) {
                sendFailNotification(e.getMessage());
                result.error("001", e.getMessage(), "");
            } catch (ConnectionException e) {
                sendFailNotification("connection fail");
                result.error("004", "Connection Fail", "");
            } catch (Exception ex) {
                result.error("100", ex.getMessage(), ex.getLocalizedMessage());
            }

        } else {
//                    disconnect();
        }
    }

    private void printPDF(String macAddress, String pathFile, Result result) {

        if (isPrinterNotConnected()) {
            printer = connect(macAddress);
        }
        try {
            if (connection.isConnected() && printer != null) {
                if (!new File(pathFile).exists()) {
                    result.error("001", "File not Exist", "");
                    return;
                }
                PDfPrintService pdfPrintService = new PDfPrintService(connection, context);

//                boolean x = pdfPrintService.print("/data/data/com.shini.eshini_ops/cache/documentNew.pdf");
                boolean x= pdfPrintService.print(pathFile);
                result.success(x);

            }

        } catch (HeadOpenException | PaperOutException | SendDataException e) {
            sendFailNotification(e.getMessage());
            result.error("001", e.getMessage(), "");
        } catch (ConnectionException e) {
            sendFailNotification("connection fail");
            result.error("004", "Connection Fail", "");
        } catch (Exception ex) {
            result.error("100", ex.getMessage(), ex.getLocalizedMessage());
        } finally {
            disconnect();
        }
    }

    private void printPDFBytes(String macAddress, byte[] pdfBytes, Result result) {

        if (isPrinterNotConnected()) {
            printer = connect(macAddress);
        }
        try {
            if (connection.isConnected() && printer != null) {
                if (pdfBytes == null || pdfBytes.length == 0) {
                    result.error("001", "PDF bytes are null or empty", "");
                    return;
                }
                
                System.out.println("Printing PDF from bytes, size: " + pdfBytes.length + " bytes");
                PDfPrintService pdfPrintService = new PDfPrintService(connection, context);

                boolean x = pdfPrintService.printPdfFromBytes(pdfBytes);
                result.success(x);

            }

        } catch (HeadOpenException | PaperOutException | SendDataException e) {
            sendFailNotification(e.getMessage());
            result.error("001", e.getMessage(), "");
        } catch (ConnectionException e) {
            sendFailNotification("connection fail");
            result.error("004", "Connection Fail", "");
        } catch (Exception ex) {
            result.error("100", ex.getMessage(), ex.getLocalizedMessage());
        } finally {
            disconnect();
        }
    }

    private boolean isPrinterNotConnected() {
        if (connection == null || printer == null) return true;
        return !connection.isConnected();
    }

    public ZebraPrinter connect(String macAddress) {
        sendSuccessNotification("Connecting...");
        connection = null;
        connection = new BluetoothConnection(macAddress);

        try {
            connection.open();
        } catch (ConnectionException e) {
            sendFailNotification("Comm Error! Disconnecting error: " + e.getMessage());
            disconnect();
        }

        ZebraPrinter zebraPrinter = null;
        if (connection.isConnected()) {
            try {
                zebraPrinter = ZebraPrinterFactory.getInstance(connection);
            } catch (ConnectionException | ZebraPrinterLanguageUnknownException e) {
                sendFailNotification("Unknown Printer Language");
                disconnect();
            }
        }

        return zebraPrinter;
    }

    public void disconnect() {
        try {

            sendSuccessNotification("Disconnecting...");
            if (connection != null) {
                connection.close();
                printer = null;
                sendSuccessNotification("Disconnected Printer");
            }

            sendSuccessNotification("Not Connected");
        } catch (ConnectionException e) {

            sendFailNotification("COMM Error! Disconnected: " + e.getMessage());
        }
    }


    private EventChannel.EventSink getEventSink() {
        return eventSink;
    }

    private void setEventSink(EventChannel.EventSink eventSink) {
        this.eventSink = eventSink;
    }

    private void sendSuccessNotification(String message) {

        if (getEventSink() != null) {
            getEventSink().success(message);
        }
        io.flutter.Log.i(tag, message);
    }

    private void sendFailNotification(String message) {

        if (getEventSink() != null) {
            getEventSink().success(message);
        }
        io.flutter.Log.e(tag, message);
    }
}
