package com.shini.plus.zebra_bluetooth_printer;

import android.bluetooth.BluetoothAdapter;
import android.bluetooth.BluetoothClass;
import android.bluetooth.BluetoothDevice;
import android.bluetooth.BluetoothManager;
import android.content.BroadcastReceiver;
import android.content.Context;
import android.content.Intent;
import android.content.IntentFilter;
import android.hardware.usb.UsbDevice;
import android.hardware.usb.UsbManager;
import android.os.Build;
import android.os.Handler;
import android.os.Looper;

import androidx.annotation.NonNull;

import java.util.ArrayList;
import java.util.HashMap;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Locale;
import java.util.Map;
import java.util.Objects;
import java.util.Set;
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
import com.zebra.sdk.comm.TcpConnection;
import com.zebra.sdk.comm.UsbConnection;
import com.zebra.sdk.printer.SGD;
import com.zebra.sdk.printer.ZebraPrinter;
import com.zebra.sdk.printer.ZebraPrinterFactory;
import com.zebra.sdk.printer.ZebraPrinterLanguageUnknownException;

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
    private String connectedAddress = "";
    private String connectedTransport = "";
    private final Object printerLock = new Object();
    private final Handler mainHandler = new Handler(Looper.getMainLooper());
    private final ExecutorService printerExecutor = Executors.newSingleThreadExecutor();
    String tag = "ZebraBluetoothPrinterPlugin";
    /**
     * BluetoothClass.Device.IMAGING_PRINTER. The Zebra SDK 2.14 scan keeps only
     * this class.
     */
    private static final int IMAGING_PRINTER = 0x0680;
    private static final long DISCOVERY_TIMEOUT_MS = 13000L;
    private static final long IDLE_DISCONNECT_MS = 5 * 60 * 1000L;
    private final Runnable idleDisconnect = () -> {
        synchronized (printerLock) {
            disconnect();
        }
    };

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
        mainHandler.removeCallbacks(idleDisconnect);
        disconnect();
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
            case MethodChannels.PRINT_PDFS:
                List<String> argPdfs = call.arguments();
                printerExecutor.execute(() -> printPDFs(argPdfs, result));
                break;
            case MethodChannels.HOST_IDENTIFICATION:
                String hostMac = call.arguments();
                printerExecutor.execute(() -> hostIdentification(hostMac, result));
                break;
            case MethodChannels.SDK:
                Map<?, ?> sdkArgs = call.arguments();
                printerExecutor.execute(() -> runSdk(sdkArgs, result));
                break;
            default:
                result.notImplemented();
                break;
        }
    }

    /**
     * Zebra SDK 2.14 registers its discovery receiver without RECEIVER_EXPORTED.
     * Samsung One UI on Android 13+ rejects that registration, so the scan ends
     * with no printers. Samsung also omits the printer device class and hides
     * already-paired printers from inquiry results. List paired printers first,
     * then run our own classic scan.
     */
    private void discoverPrinters(Result result) {
        BluetoothAdapter adapter = bluetoothAdapter();
        if (adapter == null) {
            result.error("004", "No bluetooth radio found", null);
            return;
        }
        if (!adapter.isEnabled()) {
            result.error("004", "Bluetooth radio is currently disabled", null);
            return;
        }

        Map<String, Map<String, String>> found = new LinkedHashMap<>();
        addBondedPrinters(adapter, found);

        AtomicBoolean replied = new AtomicBoolean(false);
        AtomicBoolean ignoreNextFinish = new AtomicBoolean(false);
        final Runnable[] timeout = new Runnable[1];
        final BroadcastReceiver[] receiver = new BroadcastReceiver[1];
        receiver[0] = new BroadcastReceiver() {
            @Override
            public void onReceive(Context context, Intent intent) {
                if (intent == null || intent.getAction() == null)
                    return;
                if (BluetoothDevice.ACTION_FOUND.equals(intent.getAction())) {
                    BluetoothDevice device = bluetoothDeviceExtra(intent);
                    if (device != null && isLikelyPrinter(device)) {
                        synchronized (found) {
                            addPrinter(found, device);
                        }
                    }
                    return;
                }
                if (BluetoothAdapter.ACTION_DISCOVERY_FINISHED.equals(intent.getAction())) {
                    if (ignoreNextFinish.compareAndSet(true, false))
                        return;
                    finishDiscovery(result, replied, receiver[0], found, timeout[0]);
                }
            }
        };

        IntentFilter filter = new IntentFilter();
        filter.addAction(BluetoothDevice.ACTION_FOUND);
        filter.addAction(BluetoothAdapter.ACTION_DISCOVERY_FINISHED);
        try {
            registerDiscoveryReceiver(receiver[0], filter);
        } catch (Exception e) {
            io.flutter.Log.e(tag, "Unable to register bluetooth receiver: " + e.getMessage());
            replyPrinters(result, replied, found);
            return;
        }

        timeout[0] = () -> finishDiscovery(result, replied, receiver[0], found, timeout[0]);
        mainHandler.postDelayed(timeout[0], DISCOVERY_TIMEOUT_MS);

        boolean started = false;
        try {
            if (adapter.isDiscovering()) {
                ignoreNextFinish.set(true);
                adapter.cancelDiscovery();
            }
            started = adapter.startDiscovery();
        } catch (SecurityException e) {
            io.flutter.Log.e(tag, "Bluetooth discovery permission denied: " + e.getMessage());
        }

        if (!started) {
            ignoreNextFinish.set(false);
            io.flutter.Log.e(tag, "Bluetooth discovery did not start; returning paired printers only");
            finishDiscovery(result, replied, receiver[0], found, timeout[0]);
        }
    }

    private void finishDiscovery(Result result, AtomicBoolean replied, BroadcastReceiver receiver,
            Map<String, Map<String, String>> found, Runnable timeout) {
        if (!replied.compareAndSet(false, true))
            return;
        if (timeout != null)
            mainHandler.removeCallbacks(timeout);
        try {
            BluetoothAdapter adapter = bluetoothAdapter();
            if (adapter != null && adapter.isDiscovering())
                adapter.cancelDiscovery();
        } catch (SecurityException ignored) {
        }
        try {
            applicationContext.unregisterReceiver(receiver);
        } catch (Exception ignored) {
        }
        replyPrinters(result, replied, found);
    }

    private void replyPrinters(Result result, AtomicBoolean replied,
            Map<String, Map<String, String>> found) {
        replied.set(true);
        List<Map<String, String>> copy;
        synchronized (found) {
            copy = new ArrayList<>(found.values());
        }
        io.flutter.Log.i(tag, "Printers found: " + copy.size());
        replySuccess(result, copy);
    }

    private void addBondedPrinters(BluetoothAdapter adapter, Map<String, Map<String, String>> found) {
        try {
            Set<BluetoothDevice> bonded = adapter.getBondedDevices();
            if (bonded == null)
                return;
            for (BluetoothDevice device : bonded) {
                if (isLikelyPrinter(device)) {
                    addPrinter(found, device);
                }
            }
        } catch (SecurityException e) {
            io.flutter.Log.e(tag, "Cannot read paired devices: " + e.getMessage());
        }
    }

    private void addPrinter(Map<String, Map<String, String>> found, BluetoothDevice device) {
        String address = device.getAddress();
        if (address == null || address.isEmpty() || found.containsKey(address))
            return;
        String name = safeName(device);
        if (name == null || name.isEmpty())
            name = address;
        Map<String, String> item = new HashMap<>();
        item.put("name", name);
        item.put("address", address);
        item.put("serialNumber", address);
        found.put(address, item);
    }

    private boolean isLikelyPrinter(BluetoothDevice device) {
        if (isZebraName(safeName(device)))
            return true;
        try {
            BluetoothClass btClass = device.getBluetoothClass();
            if (btClass == null)
                return false;
            if (btClass.getDeviceClass() == IMAGING_PRINTER)
                return true;
            // Samsung often reports Zebra printers as imaging with no printer minor class.
            return btClass.getMajorDeviceClass() == BluetoothClass.Device.Major.IMAGING;
        } catch (SecurityException e) {
            return false;
        }
    }

    private boolean isZebraName(String name) {
        if (name == null || name.isEmpty())
            return false;
        String upper = name.toUpperCase(Locale.US);
        return upper.startsWith("XX")
                || upper.contains("ZEBRA")
                || upper.startsWith("ZD")
                || upper.startsWith("ZQ")
                || upper.startsWith("ZT")
                || upper.startsWith("GK")
                || upper.startsWith("GX")
                || upper.startsWith("QLN");
    }

    private String safeName(BluetoothDevice device) {
        try {
            return device.getName();
        } catch (SecurityException e) {
            return null;
        }
    }

    private BluetoothDevice bluetoothDeviceExtra(Intent intent) {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            return intent.getParcelableExtra(BluetoothDevice.EXTRA_DEVICE, BluetoothDevice.class);
        }
        return intent.getParcelableExtra(BluetoothDevice.EXTRA_DEVICE);
    }

    private void registerDiscoveryReceiver(BroadcastReceiver receiver, IntentFilter filter) {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            applicationContext.registerReceiver(receiver, filter, Context.RECEIVER_EXPORTED);
        } else {
            applicationContext.registerReceiver(receiver, filter);
        }
    }

    private BluetoothAdapter bluetoothAdapter() {
        BluetoothManager manager = (BluetoothManager) applicationContext.getSystemService(Context.BLUETOOTH_SERVICE);
        if (manager != null && manager.getAdapter() != null) {
            return manager.getAdapter();
        }
        return BluetoothAdapter.getDefaultAdapter();
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

    private void hostIdentification(String macAddress, Result result) {
        synchronized (printerLock) {
            try {
                if (isPrinterNotConnected()) {
                    printer = connect(macAddress);
                }
                if (connection == null || !connection.isConnected()) {
                    replySuccess(result, "");
                    return;
                }
                String host = SGD.GET("device.host_identification", connection);
                replySuccess(result, host == null ? "" : host);
            } catch (Exception e) {
                replySuccess(result, "");
            }
        }
    }

    private void printPDFs(List<String> args, Result result) {
        if (args == null || args.size() < 2) {
            replyError(result, "100", "Expected printer and at least one PDF");
            return;
        }
        synchronized (printerLock) {
            try {
                ensureBluetoothConnected(args.get(0));
                if (connection == null || !connection.isConnected() || printer == null) {
                    replyError(result, "004", "Not Connected");
                    return;
                }
                PDfPrintService pdfPrintService = new PDfPrintService(connection);
                boolean printed = true;
                for (int i = 1; i < args.size(); i++) {
                    printed = pdfPrintService.print(args.get(i), i == 1, i == args.size() - 1) && printed;
                }
                replySuccess(result, printed);
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
                ensureBluetoothConnected(macAddress);
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
            }
        }
    }

    private void ensureBluetoothConnected(String macAddress) {
        if (!isPrinterNotConnected()
                && macAddress != null
                && macAddress.equalsIgnoreCase(connectedAddress)) {
            noteSessionUsed();
            return;
        }
        disconnect();
        printer = connect(macAddress);
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
            ZebraPrinter instance = ZebraPrinterFactory.getInstance(connection);
            noteSessionUsed();
            return instance;
        } catch (ConnectionException | ZebraPrinterLanguageUnknownException e) {
            sendFailNotification("Unknown Printer Language");
            disconnect();
            return null;
        }
    }

    private void noteSessionUsed() {
        mainHandler.removeCallbacks(idleDisconnect);
        mainHandler.postDelayed(idleDisconnect, IDLE_DISCONNECT_MS);
    }

    public void disconnect() {
        mainHandler.removeCallbacks(idleDisconnect);
        Connection current = connection;
        connection = null;
        printer = null;
        connectedAddress = "";
        connectedTransport = "";
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

    private void runSdk(Map<?, ?> args, Result result) {
        synchronized (printerLock) {
            try {
                Object value = new SdkOperations(this).execute(args == null ? new HashMap<String, Object>() : args);
                replySuccess(result, value);
            } catch (HeadOpenException | PaperOutException | SendDataException e) {
                sendFailNotification(e.getMessage());
                replyError(result, "001", e.getMessage());
            } catch (ConnectionException e) {
                sendFailNotification("connection fail");
                replyError(result, "004", e.getMessage() == null ? "Connection Fail" : e.getMessage());
            } catch (Exception ex) {
                sendFailNotification(ex.getMessage());
                replyError(result, "100", ex.getMessage());
            }
        }
    }

    Context appContext() {
        return applicationContext;
    }

    Connection sessionConnection() {
        return connection;
    }

    ZebraPrinter sessionPrinter() {
        return printer;
    }

    void openSession(String transport, String address, int port) throws Exception {
        synchronized (printerLock) {
            String kind = transport == null || transport.isEmpty() ? "bluetooth" : transport;
            if (connection != null && connection.isConnected()
                    && kind.equals(connectedTransport)
                    && address != null
                    && address.equalsIgnoreCase(connectedAddress)) {
                return;
            }
            if ("tcp".equals(kind)) {
                openTcp(address, port);
            } else if ("usb".equals(kind)) {
                openUsb(address);
            } else {
                printer = connect(address);
                if (connection == null || !connection.isConnected() || printer == null) {
                    throw new ConnectionException("Connection Fail");
                }
                connectedAddress = address;
                connectedTransport = "bluetooth";
            }
        }
    }

    private void openTcp(String host, int port) throws Exception {
        disconnect();
        int tcpPort = port <= 0 ? TcpConnection.DEFAULT_ZPL_TCP_PORT : port;
        connection = new TcpConnection(host, tcpPort);
        try {
            connection.open();
            printer = ZebraPrinterFactory.getInstance(connection);
        } catch (Exception e) {
            disconnect();
            throw e;
        }
        connectedAddress = host;
        connectedTransport = "tcp";
        sendSuccessNotification("Connected");
    }

    private void openUsb(String address) throws Exception {
        SdkOperations usb = new SdkOperations(this);
        UsbDevice device = usb.findUsb(address == null ? "" : address);
        if (device == null) {
            throw new ConnectionException("No Zebra USB printer");
        }
        UsbManager manager = (UsbManager) applicationContext.getSystemService(Context.USB_SERVICE);
        if (manager == null) {
            throw new ConnectionException("USB is not available");
        }
        if (!manager.hasPermission(device)) {
            usb.requestUsbPermission(device);
            throw new ConnectionException("USB permission requested. Allow it, then connect again.");
        }
        disconnect();
        connection = new UsbConnection(manager, device);
        try {
            connection.open();
            printer = ZebraPrinterFactory.getInstance(connection);
        } catch (Exception e) {
            disconnect();
            throw e;
        }
        connectedAddress = device.getDeviceName();
        connectedTransport = "usb";
        sendSuccessNotification("Connected");
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
