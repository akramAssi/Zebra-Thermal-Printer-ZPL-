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

    public PDfPrintService(Connection connection) {
        this.connection = connection;
    }

    public boolean print(String path)
            throws ConnectionException, SendDataException, HeadOpenException, PaperOutException {

        // Get Instance of Printer
        ZebraPrinterLinkOs printer = ZebraPrinterFactory.getLinkOsPrinter(connection);
        if (printer == null) {
            throw new ConnectionException("Printer is not a Link-OS printer");
        }

        // Verify Printer Status is Ready
        PrinterStatus printerStatus = printer.getCurrentStatus();
        if (printerStatus.isReadyToPrint) {
            String scale = scalePrint(connection);
            SGD.SET("apl.settings", scale, connection);
            String previousMedia = readSetting("ezpl.media_type");
            setSetting("ezpl.media_type", "continuous");
            try {
                printer.sendFileContents(path);
                waitUntilPrinterIdle(printer);
            } finally {
                if (previousMedia != null && !previousMedia.isEmpty()
                        && !"continuous".equalsIgnoreCase(previousMedia)) {
                    setSetting("ezpl.media_type", previousMedia);
                }
            }
            return true;
            // TODO: Notify UI that print job completed successfully...
        } else {
            if (printerStatus.isPaused) {
                throw new SendDataException("Fail Print");
            } else if (printerStatus.isHeadOpen) {
                throw new HeadOpenException();
            } else if (printerStatus.isPaperOut) {
                throw new PaperOutException();
            }
        }

        return false;

    }

    private void waitUntilPrinterIdle(ZebraPrinterLinkOs printer) throws ConnectionException {
        try {
            for (int attempt = 0; attempt < 20; attempt++) {
                PrinterStatus status = printer.getCurrentStatus();
                if (status.numberOfFormatsInReceiveBuffer == 0 && !status.isPartialFormatInProgress) {
                    return;
                }
                Thread.sleep(200);
            }
        } catch (InterruptedException e) {
            Thread.currentThread().interrupt();
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
            return "dither scale=100x100";
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
            return "dither scale=100x100";
        }
        return "dither scale=" + (int) scaleFactor + "x" + (int) scaleFactor;
    }
}
