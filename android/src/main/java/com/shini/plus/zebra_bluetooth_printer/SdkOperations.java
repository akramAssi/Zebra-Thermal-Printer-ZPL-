package com.shini.plus.zebra_bluetooth_printer;

import android.app.PendingIntent;
import android.content.Context;
import android.content.Intent;
import android.hardware.usb.UsbDevice;
import android.hardware.usb.UsbManager;
import android.os.Build;

import com.shini.plus.zebra_bluetooth_printer.exception.HeadOpenException;
import com.shini.plus.zebra_bluetooth_printer.exception.PaperOutException;
import com.shini.plus.zebra_bluetooth_printer.exception.SendDataException;
import com.shini.plus.zebra_bluetooth_printer.services.PDfPrintService;
import com.zebra.sdk.comm.Connection;
import com.zebra.sdk.comm.ConnectionException;
import com.zebra.sdk.graphics.ZebraImageFactory;
import com.zebra.sdk.graphics.ZebraImageI;
import com.zebra.sdk.printer.SGD;
import com.zebra.sdk.printer.StorageInfo;
import com.zebra.sdk.printer.ZebraPrinter;
import com.zebra.sdk.printer.ZebraPrinterFactory;
import com.zebra.sdk.printer.ZebraPrinterLinkOs;
import com.zebra.sdk.printer.discovery.DiscoveredPrinter;
import com.zebra.sdk.printer.discovery.DiscoveryHandler;
import com.zebra.sdk.printer.discovery.NetworkDiscoverer;
import com.zebra.sdk.printer.discovery.UsbDiscoverer;

import java.nio.charset.StandardCharsets;
import java.util.ArrayList;
import java.util.Collections;
import java.util.HashMap;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.TimeUnit;

/**
 * Link-OS SDK calls used by {@code ZebraSdk} on the Flutter side.
 * The plugin owns the open connection. This class only uses it.
 */
final class SdkOperations {
    static final String USB_PERMISSION = "com.shini.plus.zebra_bluetooth_printer.USB_PERMISSION";

    private final ZebraBluetoothPrinterPlugin plugin;

    SdkOperations(ZebraBluetoothPrinterPlugin plugin) {
        this.plugin = plugin;
    }

    Object execute(Map<?, ?> args) throws Exception {
        String op = text(args, "op");
        switch (op) {
            case "discoverNetwork":
                return discoverNetwork(args);
            case "discoverUsb":
                return discoverUsb();
            case "connect":
                plugin.openSession(text(args, "transport"), text(args, "address"), number(args, "port", 9100));
                return true;
            case "disconnect":
                plugin.disconnect();
                return true;
            case "isConnected":
                Connection open = plugin.sessionConnection();
                return open != null && open.isConnected();
            case "status":
                requireSession(args);
                return statusMap(plugin.sessionPrinter().getCurrentStatus());
            case "get":
                requireSession(args);
                return safe(SGD.GET(text(args, "setting"), plugin.sessionConnection()));
            case "set":
                requireSession(args);
                SGD.SET(text(args, "setting"), text(args, "value"), plugin.sessionConnection());
                return true;
            case "do":
                requireSession(args);
                return safe(SGD.DO(text(args, "command"), text(args, "value"), plugin.sessionConnection()));
            case "hostInfo":
                requireSession(args);
                return hostInfo();
            case "printZpl":
                requireSession(args);
                SGD.SET("device.languages", "zpl", plugin.sessionConnection());
                assertReady();
                plugin.sessionConnection().write(text(args, "data").getBytes(StandardCharsets.UTF_8));
                return true;
            case "printCpcl":
                requireSession(args);
                try {
                    SGD.SET("device.languages", "cpcl", plugin.sessionConnection());
                } catch (ConnectionException ignored) {
                }
                plugin.sessionConnection().write(text(args, "data").getBytes(StandardCharsets.UTF_8));
                return true;
            case "printRaw":
                requireSession(args);
                plugin.sessionConnection().write(bytes(args, "bytes"));
                return true;
            case "printPdfs":
                requireSession(args);
                return printPdfs(stringList(args, "paths"));
            case "printImage":
                requireSession(args);
                printImage(args);
                return true;
            case "storeImage":
                requireSession(args);
                storeImage(args);
                return true;
            case "calibrate":
                requireSession(args);
                plugin.sessionPrinter().calibrate();
                return true;
            case "printConfigurationLabel":
                requireSession(args);
                plugin.sessionPrinter().printConfigurationLabel();
                return true;
            case "printNetworkConfigurationLabel":
                requireSession(args);
                plugin.sessionConnection().write("~WL\r\n".getBytes(StandardCharsets.UTF_8));
                return true;
            case "printDirectoryLabel":
                requireSession(args);
                plugin.sessionConnection().write("^XA^WD*:*.*^XZ".getBytes(StandardCharsets.UTF_8));
                return true;
            case "feed":
                requireSession(args);
                plugin.sessionConnection().write("^XA^PH^XZ".getBytes(StandardCharsets.UTF_8));
                return true;
            case "restoreDefaults":
                requireSession(args);
                plugin.sessionPrinter().restoreDefaults();
                return true;
            case "reset":
                requireSession(args);
                plugin.sessionPrinter().reset();
                return true;
            case "listFiles":
                requireSession(args);
                return listFiles(text(args, "drive"));
            case "storeFile":
                requireSession(args);
                linkOs().storeFileOnPrinter(text(args, "path"), text(args, "printerPath"));
                return true;
            case "sendFile":
                requireSession(args);
                plugin.sessionPrinter().sendFileContents(text(args, "path"));
                return true;
            case "deleteFile":
                requireSession(args);
                linkOs().deleteFile(text(args, "printerPath"));
                return true;
            case "retrieveFile":
                requireSession(args);
                return linkOs().getObjectFromPrinter(text(args, "printerPath"));
            case "printStoredFormat":
                requireSession(args);
                plugin.sessionPrinter().printStoredFormat(
                        text(args, "printerPath"),
                        fieldMap(args.get("fields")));
                return true;
            case "storageInfo":
                requireSession(args);
                return storageInfo();
            case "odometer":
                requireSession(args);
                return odometer();
            case "setClock":
                requireSession(args);
                SGD.SET("rtc.date", text(args, "date"), plugin.sessionConnection());
                SGD.SET("rtc.time", text(args, "time"), plugin.sessionConnection());
                return true;
            default:
                throw new IllegalArgumentException("Unknown SDK operation " + op);
        }
    }

    private void requireSession(Map<?, ?> args) throws Exception {
        String address = text(args, "address");
        if (address.isEmpty()) {
            Connection connection = plugin.sessionConnection();
            if (connection == null || !connection.isConnected() || plugin.sessionPrinter() == null) {
                throw new ConnectionException("Not Connected");
            }
            return;
        }
        String transport = text(args, "transport");
        if (transport.isEmpty()) {
            transport = "bluetooth";
        }
        plugin.openSession(transport, address, number(args, "port", 9100));
    }

    private boolean printPdfs(List<String> paths) throws Exception {
        if (paths.isEmpty()) {
            throw new IllegalArgumentException("Expected at least one PDF");
        }
        PDfPrintService service = new PDfPrintService(plugin.sessionConnection());
        boolean printed = true;
        for (String path : paths) {
            printed = service.print(path) && printed;
        }
        return printed;
    }

    private void printImage(Map<?, ?> args) throws Exception {
        String path = text(args, "path");
        int x = number(args, "x", 0);
        int y = number(args, "y", 0);
        int width = number(args, "width", 0);
        int height = number(args, "height", 0);
        if (width <= 0 || height <= 0) {
            plugin.sessionPrinter().printImage(path, x, y);
            return;
        }
        ZebraImageI image = ZebraImageFactory.getImage(path);
        plugin.sessionPrinter().printImage(image, x, y, width, height, false);
    }

    private void storeImage(Map<?, ?> args) throws Exception {
        String path = text(args, "path");
        int width = number(args, "width", 0);
        int height = number(args, "height", 0);
        ZebraImageI image = ZebraImageFactory.getImage(path);
        if (width <= 0) {
            width = image.getWidth();
        }
        if (height <= 0) {
            height = image.getHeight();
        }
        plugin.sessionPrinter().storeImage(text(args, "printerPath"), image, width, height);
    }

    private void assertReady() throws Exception {
        com.zebra.sdk.printer.PrinterStatus status = plugin.sessionPrinter().getCurrentStatus();
        if (status.isReadyToPrint) {
            return;
        }
        if (status.isHeadOpen) {
            throw new HeadOpenException();
        }
        if (status.isPaperOut) {
            throw new PaperOutException();
        }
        if (status.isPaused) {
            throw new SendDataException("Fail Print");
        }
        throw new SendDataException("Fail Print");
    }

    private Map<String, Object> statusMap(com.zebra.sdk.printer.PrinterStatus status) {
        Map<String, Object> map = new LinkedHashMap<>();
        map.put("isReadyToPrint", status.isReadyToPrint);
        map.put("isPaused", status.isPaused);
        map.put("isHeadOpen", status.isHeadOpen);
        map.put("isPaperOut", status.isPaperOut);
        map.put("isRibbonOut", status.isRibbonOut);
        map.put("isHeadCold", status.isHeadCold);
        map.put("isHeadTooHot", status.isHeadTooHot);
        map.put("isReceiveBufferFull", status.isReceiveBufferFull);
        map.put("isPartialFormatInProgress", status.isPartialFormatInProgress);
        map.put("labelLengthInDots", status.labelLengthInDots);
        map.put("numberOfFormatsInReceiveBuffer", status.numberOfFormatsInReceiveBuffer);
        map.put("labelsRemainingInBatch", status.labelsRemainingInBatch);
        map.put("printMode", status.printMode == null ? "" : status.printMode.toString());
        return map;
    }

    private Map<String, String> hostInfo() {
        Map<String, String> info = new LinkedHashMap<>();
        String[] keys = {
                "device.host_identification",
                "device.product_name",
                "device.friendly_name",
                "appl.name",
                "device.languages",
                "ezpl.media_type",
                "ezpl.print_width",
                "zpl.label_length",
                "print.tone",
                "media.speed",
                "power.percent_full",
                "ip.addr",
        };
        Connection connection = plugin.sessionConnection();
        for (String key : keys) {
            try {
                info.put(key, safe(SGD.GET(key, connection)));
            } catch (ConnectionException ignored) {
            }
        }
        try {
            info.put("language", plugin.sessionPrinter().getPrinterControlLanguage().toString());
        } catch (Exception ignored) {
        }
        try {
            ZebraPrinterLinkOs link = ZebraPrinterFactory.createLinkOsPrinter(plugin.sessionPrinter());
            if (link != null && link.getLinkOsInformation() != null) {
                info.put("linkos", link.getLinkOsInformation().getMajor()
                        + "." + link.getLinkOsInformation().getMinor());
            }
        } catch (Exception ignored) {
        }
        return info;
    }

    private Map<String, String> odometer() {
        Map<String, String> info = new LinkedHashMap<>();
        String[] keys = {
                "odometer.total_label_count",
                "odometer.user_label_count",
                "odometer.media_marker_count",
                "odometer.headclean_count",
        };
        Connection connection = plugin.sessionConnection();
        for (String key : keys) {
            try {
                info.put(key, safe(SGD.GET(key, connection)));
            } catch (ConnectionException ignored) {
            }
        }
        return info;
    }

    private List<Map<String, Object>> storageInfo() throws Exception {
        List<Map<String, Object>> rows = new ArrayList<>();
        for (StorageInfo info : linkOs().getStorageInfo()) {
            Map<String, Object> row = new LinkedHashMap<>();
            row.put("driveLetter", String.valueOf(info.driveLetter));
            row.put("driveType", info.driveType == null ? "" : info.driveType.toString());
            row.put("bytesFree", info.bytesFree);
            row.put("isPersistent", info.isPersistent);
            rows.add(row);
        }
        return rows;
    }

    private List<String> listFiles(String drive) throws Exception {
        String[] names = plugin.sessionPrinter().retrieveFileNames();
        List<String> files = new ArrayList<>();
        String prefix = drive == null ? "" : drive.trim().toUpperCase();
        if (names == null) {
            return files;
        }
        for (String name : names) {
            if (name == null || name.isEmpty()) {
                continue;
            }
            if (prefix.isEmpty() || name.toUpperCase().startsWith(prefix)) {
                files.add(name);
            }
        }
        return files;
    }

    private ZebraPrinterLinkOs linkOs() throws ConnectionException {
        ZebraPrinterLinkOs link = ZebraPrinterFactory.createLinkOsPrinter(plugin.sessionPrinter());
        if (link == null) {
            throw new ConnectionException("Printer is not a Link-OS printer");
        }
        return link;
    }

    private List<Map<String, Object>> discoverNetwork(Map<?, ?> args) throws Exception {
        List<Map<String, Object>> found = Collections.synchronizedList(new ArrayList<>());
        CountDownLatch done = new CountDownLatch(1);
        DiscoveryHandler handler = new DiscoveryHandler() {
            @Override
            public void foundPrinter(DiscoveredPrinter printer) {
                found.add(printerMap(printer, "tcp"));
            }

            @Override
            public void discoveryFinished() {
                done.countDown();
            }

            @Override
            public void discoveryError(String message) {
                done.countDown();
            }
        };
        String subnet = text(args, "subnet");
        if (subnet.isEmpty()) {
            NetworkDiscoverer.findPrinters(handler);
        } else {
            NetworkDiscoverer.subnetSearch(handler, subnet);
        }
        done.await(number(args, "timeoutMs", 8000), TimeUnit.MILLISECONDS);
        return new ArrayList<>(found);
    }

    private List<Map<String, Object>> discoverUsb() {
        List<Map<String, Object>> found = new ArrayList<>();
        UsbManager manager = usbManager();
        if (manager == null) {
            return found;
        }
        for (UsbDevice device : manager.getDeviceList().values()) {
            if (!UsbDiscoverer.isZebraUsbDevice(device)) {
                continue;
            }
            Map<String, Object> row = new LinkedHashMap<>();
            String product = device.getProductName();
            row.put("name", product == null || product.isEmpty() ? "Zebra USB" : product);
            row.put("address", device.getDeviceName());
            row.put("transport", "usb");
            row.put("port", 0);
            found.add(row);
        }
        return found;
    }

    Map<String, Object> printerMap(DiscoveredPrinter printer, String transport) {
        Map<String, Object> row = new LinkedHashMap<>();
        Map<String, String> data = printer.getDiscoveryDataMap();
        String name = "";
        if (data != null) {
            name = first(data, "SYSTEM_NAME", "PRODUCT_NAME", "DNS_NAME");
        }
        if (name.isEmpty()) {
            name = printer.address;
        }
        row.put("name", name);
        row.put("address", printer.address);
        row.put("transport", transport);
        int port = 9100;
        if (data != null && data.get("PORT_NUMBER") != null) {
            try {
                port = Integer.parseInt(data.get("PORT_NUMBER"));
            } catch (NumberFormatException ignored) {
            }
        }
        row.put("port", port);
        row.put("discovery", data == null ? new HashMap<String, String>() : data);
        return row;
    }

    void requestUsbPermission(UsbDevice device) {
        UsbManager manager = usbManager();
        if (manager == null || device == null) {
            return;
        }
        int flags = Build.VERSION.SDK_INT >= 31 ? PendingIntent.FLAG_MUTABLE : 0;
        PendingIntent pending = PendingIntent.getBroadcast(
                plugin.appContext(),
                0,
                new Intent(USB_PERMISSION),
                flags);
        manager.requestPermission(device, pending);
    }

    UsbDevice findUsb(String address) {
        UsbManager manager = usbManager();
        if (manager == null) {
            return null;
        }
        for (UsbDevice device : manager.getDeviceList().values()) {
            if (!UsbDiscoverer.isZebraUsbDevice(device)) {
                continue;
            }
            String serial = "";
            try {
                serial = device.getSerialNumber();
            } catch (SecurityException ignored) {
            }
            if (address.isEmpty()
                    || address.equals(device.getDeviceName())
                    || address.equals(device.getProductName())
                    || address.equals(serial)) {
                return device;
            }
        }
        return null;
    }

    private UsbManager usbManager() {
        Context context = plugin.appContext();
        if (context == null) {
            return null;
        }
        return (UsbManager) context.getSystemService(Context.USB_SERVICE);
    }

    private static Map<Integer, String> fieldMap(Object raw) {
        Map<Integer, String> fields = new LinkedHashMap<>();
        if (!(raw instanceof Map)) {
            return fields;
        }
        Map<?, ?> map = (Map<?, ?>) raw;
        for (Map.Entry<?, ?> entry : map.entrySet()) {
            fields.put(Integer.parseInt(entry.getKey().toString()), entry.getValue().toString());
        }
        return fields;
    }

    private static List<String> stringList(Map<?, ?> args, String key) {
        Object raw = args.get(key);
        List<String> values = new ArrayList<>();
        if (raw instanceof List) {
            for (Object item : (List<?>) raw) {
                if (item != null) {
                    values.add(item.toString());
                }
            }
        }
        return values;
    }

    private static byte[] bytes(Map<?, ?> args, String key) {
        Object raw = args.get(key);
        if (raw instanceof byte[]) {
            return (byte[]) raw;
        }
        return new byte[0];
    }

    private static String text(Map<?, ?> args, String key) {
        Object value = args.get(key);
        return value == null ? "" : value.toString();
    }

    private static int number(Map<?, ?> args, String key, int fallback) {
        Object value = args.get(key);
        if (value instanceof Number) {
            return ((Number) value).intValue();
        }
        if (value instanceof String) {
            try {
                return Integer.parseInt((String) value);
            } catch (NumberFormatException ignored) {
                return fallback;
            }
        }
        return fallback;
    }

    private static String safe(String value) {
        return value == null ? "" : value;
    }

    private static String first(Map<String, String> data, String... keys) {
        for (String key : keys) {
            String value = data.get(key);
            if (value != null && !value.isEmpty()) {
                return value;
            }
        }
        return "";
    }
}
