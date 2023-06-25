package com.shini.plus.zebra_bluetooth_printer.services;

import android.util.Log;

import com.shini.plus.zebra_bluetooth_printer.exception.*;
import com.zebra.sdk.comm.Connection;
import com.zebra.sdk.comm.ConnectionException;
import com.zebra.sdk.printer.PrinterLanguage;
import com.zebra.sdk.printer.PrinterStatus;
import com.zebra.sdk.printer.SGD;
import com.zebra.sdk.printer.ZebraPrinter;
import com.zebra.sdk.printer.ZebraPrinterFactory;
import com.zebra.sdk.printer.ZebraPrinterLinkOs;

public class ZPLPrintServices {

    private final Connection connection;
    private final ZebraPrinter printer;

    public ZPLPrintServices(Connection connection, ZebraPrinter printer) {
        this.connection = connection;
        this.printer = printer;
    }

    public boolean print(String zpl) throws Exception {

        ZebraPrinterLinkOs linkOsPrinter = ZebraPrinterFactory.createLinkOsPrinter(printer);

        PrinterStatus printerStatus = (linkOsPrinter != null) ? linkOsPrinter.getCurrentStatus() : printer.getCurrentStatus();

        if (printerStatus.isReadyToPrint) {
            byte[] configLabel = getConfigLabel(zpl);
            connection.write(configLabel);

            return true;
        } else if (printerStatus.isHeadOpen) {
            throw new HeadOpenException();
        } else if (printerStatus.isPaused) {

            throw new SendDataException("Fail Print");

        } else if (printerStatus.isPaperOut) {
            throw new PaperOutException();
        }


//        catch (ConnectionException e) {
//            if (eventSink != null)
//                eventSink.success(e.getMessage());
//
//        }
        return false;
    }

    private byte[] getConfigLabel(String zpl) {
        byte[] configLabel = null;
        try {
            PrinterLanguage printerLanguage = printer.getPrinterControlLanguage();
            SGD.SET("device.languages", "zpl", connection);


            if (printerLanguage == PrinterLanguage.ZPL) {

                //para configurar un formato de impresion diseñarlo en la siguiente pagina http://labelary.com/viewer.html

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
