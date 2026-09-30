package com.shini.plus.zebra_bluetooth_printer;

import android.content.Context;
import android.os.Handler;
import android.os.Looper;

import androidx.annotation.NonNull;

import java.util.ArrayList;
import java.util.HashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;
import java.util.concurrent.atomic.AtomicBoolean;

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
import com.zebra.sdk.printer.discovery.BluetoothDiscoverer;
import com.zebra.sdk.printer.discovery.DiscoveredPrinter;
import com.zebra.sdk.printer.discovery.DiscoveredPrinterBluetooth;
import com.zebra.sdk.printer.discovery.DiscoveryHandler;

/**
 * ZebraBluetoothPrinterPlugin
 */
public class ZebraBluetoothPrinterPlugin implements FlutterPlugin, MethodCallHandler, EventChannel.StreamHandler {
    /// The MethodChannel that will the communication between Flutter and native
    /// Android
    ///
    /// This local reference serves to register the plugin with the Flutter Engine
    /// and unregister it
    /// when the Flutter Engine is detached from the Activity
    private MethodChannel channel;
    private Context applicationContext;
    private EventChannel.EventSink eventSink;
    private Connection connection;
    private ZebraPrinter printer;
    private final Object printerLock = new Object();
    private final Handler mainHandler = new Handler(Looper.getMainLooper());
    private final ExecutorService printerExecutor = Executors.newSingleThreadExecutor();
    String tag = "ZebraBluetoothPrinterPlugin";

    @Override
    public void onAttachedToEngine(@NonNull FlutterPluginBinding flutterPluginBinding) {
        applicationContext = flutterPluginBinding.getApplicationContext();
        channel = new MethodChannel(flutterPluginBinding.getBinaryMessenger(), "zebra_bluetooth_printer");
        channel.setMethodCallHandler(this);
        EventChannel eventChannel = new EventChannel(flutterPluginBinding.getBinaryMessenger(),
                "zebra_bluetooth_printer_stream");
        eventChannel.setStreamHandler(this);
    }

    @Override
    public void onDetachedFromEngine(@NonNull FlutterPluginBinding binding) {
        channel.setMethodCallHandler(null);
        printerExecutor.shutdownNow();
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
            case MethodChannels.LIST_PRINTERS:
                discoverPrinters(result);
                break;
            case MethodChannels.CONNECT:
                String macAddress = call.arguments();
                printerExecutor.execute(() -> connectAndReply(macAddress, result));
                break;
            case MethodChannels.DISCONNECT:
                printerExecutor.execute(() -> {
                    disconnect();
                    replySuccess(result, true);
                });
                break;
            case MethodChannels.PRINT_ZPL:
                List<String> arg;
                arg = call.arguments();
                assert (Objects.requireNonNull(arg).size() == 2);
                printerExecutor.execute(() -> printZPL(arg.get(0), arg.get(1), result));
                break;
            case MethodChannels.PRINT_PDF:
                List<String> argPdf;
                argPdf = call.arguments();
                assert (Objects.requireNonNull(argPdf).size() == 2);
                printerExecutor.execute(() -> printPDF(argPdf.get(0), argPdf.get(1), result));
                break;
            default:
                result.notImplemented();
                break;
        }
    }

    private void discoverPrinters(Result result) {
        Handler main = new Handler(Looper.getMainLooper());
        AtomicBoolean replied = new AtomicBoolean(false);
        List<Map<String, String>> found = new ArrayList<>();
        try {
            BluetoothDiscoverer.findPrinters(applicationContext, new DiscoveryHandler() {
                @Override
                public void foundPrinter(DiscoveredPrinter printer) {
                    String address = printer.address;
                    String name = address;
                    if (printer instanceof DiscoveredPrinterBluetooth) {
                        DiscoveredPrinterBluetooth bluetoothPrinter = (DiscoveredPrinterBluetooth) printer;
                        if (bluetoothPrinter.friendlyName != null && !bluetoothPrinter.friendlyName.isEmpty()) {
                            name = bluetoothPrinter.friendlyName;
                        }
                    }
                    Map<String, String> item = new HashMap<>();
                    item.put("name", name);
                    item.put("address", address);
                    item.put("serialNumber", address);
                    synchronized (found) {
                        found.add(item);
                    }
                }

                @Override
                public void discoveryFinished() {
                    if (!replied.compareAndSet(false, true))
                        return;
                    List<Map<String, String>> copy;
                    synchronized (found) {
                        copy = new ArrayList<>(found);
                    }
                    main.post(() -> result.success(copy));
                }

                @Override
                public void discoveryError(String message) {
                    // findPrinters still calls discoveryFinished after an error.
                }
            });
        } catch (ConnectionException e) {
            if (replied.compareAndSet(false, true)) {
                result.error("004", e.getMessage(), null);
            }
        }
    }

    private void connectAndReply(String macAddress, Result result) {
        synchronized (printerLock) {
            if (isPrinterNotConnected()) {
                printer = connect(macAddress);
            }
            boolean connected = connection != null && connection.isConnected() && printer != null;
            if (!connected) {
                disconnect();
            }
            replySuccess(result, connected);
        }
    }

    private void printZPL(String macAddress, String zpl, Result result) {
        synchronized (printerLock) {
            try {
                if (isPrinterNotConnected()) {
                    printer = connect(macAddress);
                }

                if (connection != null && connection.isConnected() && printer != null) {
                    ZPLPrintServices printZPLServices = new ZPLPrintServices(connection, printer);
                    replySuccess(result, printZPLServices.print(zpl));
                } else {
                    replyError(result, "004", "Not Connected");
                }
            } catch (HeadOpenException | PaperOutException | SendDataException e) {
                sendFailNotification(e.getMessage());
                replyError(result, "001", e.getMessage());
            } catch (ConnectionException e) {
                sendFailNotification("connection fail");
                replyError(result, "004", "Connection Fail");
            } catch (Exception ex) {
                replyError(result, "100", ex.getMessage());
            }
        }
    }

    private void printPDF(String macAddress, String pathFile, Result result) {
        synchronized (printerLock) {
            try {
                if (isPrinterNotConnected()) {
                    printer = connect(macAddress);
                }
                if (connection != null && connection.isConnected() && printer != null) {
                    sendSuccessNotification("Printing PDF");
                    PDfPrintService pdfPrintService = new PDfPrintService(connection);
                    boolean printed = pdfPrintService.print(pathFile);
                    sendSuccessNotification(printed ? "PDF sent" : "PDF not sent");
                    replySuccess(result, printed);
                } else {
                    sendFailNotification("Not Connected");
                    replyError(result, "004", "Not Connected");
                }
            } catch (HeadOpenException | PaperOutException | SendDataException e) {
                sendFailNotification(e.getMessage());
                replyError(result, "001", e.getMessage());
            } catch (ConnectionException e) {
                sendFailNotification("connection fail");
                replyError(result, "004", "Connection Fail");
            } catch (Exception ex) {
                replyError(result, "100", ex.getMessage());
            } finally {
                disconnect();
            }
        }
    }

    private boolean isPrinterNotConnected() {
        if (connection == null || printer == null)
            return true;
        return !connection.isConnected();
    }

    public ZebraPrinter connect(String macAddress) {
        sendSuccessNotification("Connecting...");
        connection = new BluetoothConnection(macAddress);

        try {
            connection.open();
        } catch (ConnectionException e) {
            sendFailNotification("Comm Error! Disconnecting error: " + e.getMessage());
            disconnect();
            return null;
        }

        if (connection == null || !connection.isConnected()) {
            return null;
        }

        try {
            return ZebraPrinterFactory.getInstance(connection);
        } catch (ConnectionException | ZebraPrinterLanguageUnknownException e) {
            sendFailNotification("Unknown Printer Language");
            disconnect();
            return null;
        }
    }

    public void disconnect() {
        Connection current = connection;
        connection = null;
        printer = null;
        if (current == null) {
            return;
        }
        try {
            sendSuccessNotification("Disconnecting...");
            current.close();
            sendSuccessNotification("Disconnected Printer");
        } catch (ConnectionException e) {
            sendFailNotification("COMM Error! Disconnected: " + e.getMessage());
        }
    }

    private void replySuccess(Result result, Object value) {
        mainHandler.post(() -> result.success(value));
    }

    private void replyError(Result result, String code, String message) {
        mainHandler.post(() -> result.error(code, message == null ? "" : message, ""));
    }

    private EventChannel.EventSink getEventSink() {
        return eventSink;
    }

    private void setEventSink(EventChannel.EventSink eventSink) {
        this.eventSink = eventSink;
    }

    private void sendSuccessNotification(String message) {
        if (Looper.myLooper() != Looper.getMainLooper()) {
            mainHandler.post(() -> sendSuccessNotification(message));
            return;
        }
        if (getEventSink() != null) {
            getEventSink().success(message);
        }
        io.flutter.Log.i(tag, message);
    }

    private void sendFailNotification(String message) {
        if (Looper.myLooper() != Looper.getMainLooper()) {
            mainHandler.post(() -> sendFailNotification(message));
            return;
        }
        if (getEventSink() != null) {
            getEventSink().success(message);
        }
        io.flutter.Log.e(tag, message);
    }
}
