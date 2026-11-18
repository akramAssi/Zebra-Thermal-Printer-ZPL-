package com.shini.plus.zebra_bluetooth_printer.services;

import com.shini.plus.zebra_bluetooth_printer.exception.*;
import com.zebra.sdk.comm.Connection;
import com.zebra.sdk.comm.ConnectionException;
import com.zebra.sdk.printer.PrinterStatus;
import com.zebra.sdk.printer.SGD;
import com.zebra.sdk.printer.ZebraPrinterFactory;
import com.zebra.sdk.printer.ZebraPrinterLinkOs;

public class PDfPrintService {

    private final Connection connection;
    private boolean plusPrinter;
    private String previousMedia = "";

    public PDfPrintService(Connection connection) {
        this.connection = connection;
    }

    public boolean print(String path)
            throws ConnectionException, SendDataException, HeadOpenException, PaperOutException {
        return print(path, true, true);
    }

    public boolean print(String path, boolean firstPage, boolean lastPage)
            throws ConnectionException, SendDataException, HeadOpenException, PaperOutException {

        // Get Instance of Printer
        ZebraPrinterLinkOs printer = ZebraPrinterFactory.getLinkOsPrinter(connection);
        if (printer == null) {
            throw new ConnectionException("Printer is not a Link-OS printer");
        }

        // Later pages are sent while the previous page is still printing.
        // Waiting for idle here is what made the next page start late.
        if (firstPage) {
            cancelLeftoverFormat();
            plusPrinter = isZq320Plus();
            PrinterStatus printerStatus = printer.getCurrentStatus();
            if (!printerStatus.isReadyToPrint) {
                if (printerStatus.isPaused) {
                    throw new SendDataException("Fail Print");
                } else if (printerStatus.isHeadOpen) {
                    throw new HeadOpenException();
                } else if (printerStatus.isPaperOut) {
                    throw new PaperOutException();
                }
                return false;
            }
            String scale = scalePrint(connection);
            SGD.SET("apl.settings", scale, connection);
            previousMedia = readSetting("ezpl.media_type");
            setSetting("ezpl.media_type", "continuous");
        }

        try {
            printer.sendFileContents(path);
            if (lastPage) {
                try {
                    Thread.sleep(plusPrinter ? 400 : 200);
                } catch (InterruptedException e) {
                    Thread.currentThread().interrupt();
                }
            }
        } finally {
            // A setting written now is read as part of the PDF. The Plus
            // then locks and prints nothing.
            if (lastPage && !plusPrinter && previousMedia != null && !previousMedia.isEmpty()
                    && !"continuous".equalsIgnoreCase(previousMedia)) {
                setSetting("ezpl.media_type", previousMedia);
            }
        }
        return true;
    }

    private boolean isZq320Plus() {
        String host = readSetting("device.host_identification");
        String product = readSetting("device.product_name");
        String text = (host + " " + product).toUpperCase();
        return text.contains("PLUS") || text.contains("ZQ32P");
    }

    private void cancelLeftoverFormat() {
        try {
            connection.write("~JA\r\n".getBytes());
            Thread.sleep(300);
        } catch (Exception ignored) {
        }
    }

    private String readSetting(String name) {
        try {
            String value = SGD.GET(name, connection);
            return value == null ? "" : value.trim();
        } catch (ConnectionException e) {
            return "";
        }
    }

    private void setSetting(String name, String value) {
        try {
            SGD.SET(name, value, connection);
        } catch (ConnectionException ignored) {
        }
    }

    /// The invoice PDF is 72 mm wide. Printing it at 100% keeps that height,
    /// so a receipt that fits the printer stays one label. scale-to-fit on a
    /// 4-inch ZQ520 / ZQ521 stretches the page and splits it into extra labels.
    private String scalePrint(Connection connection) throws ConnectionException {
        String hostId = SGD.GET("device.host_identification", connection);
        if (hostId == null) {
            hostId = "";
        }
        String printerModel = hostId.length() >= 5 ? hostId.substring(0, 5) : hostId;
        if (printerModel.startsWith("ZQ52") || printerModel.startsWith("ZQ32")) {
            SGD.SET("media.speed", "4", connection);
            return fastPdfSettings(100);
        }

        int fileWidth = 56;
        double scaleFactor;
        if (printerModel.equals("iMZ22") || printerModel.equals("QLn22") || printerModel.equals("ZD410")) {
            scaleFactor = 2.0 / fileWidth * 100;
        } else if (printerModel.equals("iMZ32") || printerModel.equals("QLn32") || printerModel.equals("ZQ510")) {
            scaleFactor = 3.0 / fileWidth * 100;
        } else if (printerModel.equals("QLn42") || printerModel.equals("ZD420") || printerModel.equals("ZD500")
                || printerModel.equals("ZT220") || printerModel.equals("ZT230") || printerModel.equals("ZT410")) {
            scaleFactor = 4.0 / fileWidth * 100;
        } else if (printerModel.equals("ZT420")) {
            scaleFactor = 6.5 / fileWidth * 100;
        } else {
            return fastPdfSettings(100);
        }
        return fastPdfSettings((int) scaleFactor);
    }

    /// The table is gray. Dither turns that gray into a light dot pattern
    /// so the head is not burning a solid black rule on every row.
    private String fastPdfSettings(int scale) {
        return "dither scale=" + scale + "x" + scale;
    }
}
