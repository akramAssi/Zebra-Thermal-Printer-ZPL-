package com.shini.plus.zebra_bluetooth_printer.services;

import android.content.Context;
import android.graphics.Bitmap;

import com.shini.plus.zebra_bluetooth_printer.ImageData;
import com.shini.plus.zebra_bluetooth_printer.exception.*;
import com.zebra.sdk.comm.BluetoothConnection;
import com.zebra.sdk.comm.Connection;
import com.zebra.sdk.comm.ConnectionException;
import com.zebra.sdk.graphics.internal.ZebraImageAndroid;
import com.zebra.sdk.printer.PrinterStatus;
import com.zebra.sdk.printer.SGD;
import com.zebra.sdk.printer.ZebraPrinterFactory;
import com.zebra.sdk.printer.ZebraPrinterLinkOs;


import java.io.File;
import java.io.FileInputStream;
import java.io.FileNotFoundException;
import java.io.FileOutputStream;
import java.io.IOException;
import java.io.InputStream;
import java.io.OutputStream;
import java.util.List;


public class PDfPrintService {

    private final Connection connection;
    private final Context context;

    public PDfPrintService(Connection connection, Context context) {
        this.connection = connection;
        this.context = context;
    }


    public boolean printOverBluetooth(String path) throws SendDataException, ConnectionException, HeadOpenException, PaperOutException, IOException {

        connection.open();

        // 2. Load file
        File file = new File(path);
        FileInputStream fis = new FileInputStream(file);

        // 3. Send file bytes to printer
        byte[] buffer = new byte[1024];
        int len;
        while ((len = fis.read(buffer)) > 0) {
            connection.write(buffer, 0, len);
        }

        fis.close();
        return true;
    }

    public boolean print(String path) throws ConnectionException, SendDataException, HeadOpenException, PaperOutException {
        // Check if the file is a PDF
        if (path.toLowerCase().endsWith(".pdf")) {
            return printPdfAsImages(path);
        }

        // Get Instance of Printer
        ZebraPrinterLinkOs printer = ZebraPrinterFactory.getLinkOsPrinter(connection);

        // Verify Printer Status is Ready
        PrinterStatus printerStatus = printer.getCurrentStatus();
        if (printerStatus.isReadyToPrint) {
            // Send the data to printer as a byte array.

//            String scale = scalePrint(connection);
//            SGD.SET("apl.settings", scale, connection);
            System.out.println(path);

            printer.sendFileContents(path);
//            (bytesWritten, totalBytes) -> {
//                // Calc Progress
//                double rawProgress = bytesWritten * 100 / totalBytes;
//                int progress = (int) Math.round(rawProgress);
//
//                // TODO: Update UI with progress...
//            }

            // Make sure the data got to the printer before closing the connection

//            Thread.sleep(500);
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

    /**
     * Print PDF from byte array by saving to accessible location and using sendFileContents
     * This method works with Flutter 3.27.3+ and provides better quality printing
     */
    public boolean printPdfFromBytes(byte[] pdfBytes) throws ConnectionException, SendDataException, HeadOpenException, PaperOutException {
        try {
            // Validate PDF bytes
            if (pdfBytes == null || pdfBytes.length == 0) {
                throw new SendDataException("PDF bytes are null or empty");
            }

            System.out.println("PDF bytes size: " + pdfBytes.length + " bytes");

            // Get Instance of Printer
            ZebraPrinterLinkOs printer = ZebraPrinterFactory.getLinkOsPrinter(connection);

            // Verify Printer Status is Ready
            PrinterStatus printerStatus = printer.getCurrentStatus();
            if (!printerStatus.isReadyToPrint) {
                if (printerStatus.isPaused) {
                    throw new SendDataException("Printer is paused");
                } else if (printerStatus.isHeadOpen) {
                    throw new HeadOpenException();
                } else if (printerStatus.isPaperOut) {
                    throw new PaperOutException();
                }
                return false;
            }

            // Save PDF bytes to accessible location
            String accessiblePdfPath = savePdfBytesToAccessibleLocation(pdfBytes);
            System.out.println("Saved PDF to accessible location: " + accessiblePdfPath);

            // Setup media for 2.84 inch roll width, 11 inch height and print directly
            System.out.println("Setting up media for 2.84 inch roll and printing PDF directly...");
            
            // Diagnose printer settings first
            diagnosePrinterSettings(connection);
            
            // Setup media dimensions before printing
            setupMediaFor57mmRoll(connection);
            
            // Verify settings after setup
            verifyPrinterSettings(connection);
            
            // Print PDF directly with proper media setup
            printer.sendFileContents(accessiblePdfPath);

            System.out.println("PDF printing completed successfully");
            return true;

        } catch (Exception e) {
            System.err.println("Error in printPdfFromBytes: " + e.getMessage());
            e.printStackTrace();
            throw new SendDataException("Failed to print PDF from bytes: " + e.getMessage());
        }
    }

    /**
     * Print PDF file by converting each page to an image and printing it
     * This method works with Flutter 3.27.3+ where direct PDF printing may not work
     */
    public boolean printPdfAsImages(String pdfPath) throws ConnectionException, SendDataException, HeadOpenException, PaperOutException {
        try {
            // Check if we can access the file directly
            File pdfFile = new File(pdfPath);
            System.out.println("Checking file: " + pdfPath);
            System.out.println("File exists: " + pdfFile.exists());
            System.out.println("File can read: " + pdfFile.canRead());
            System.out.println("File is file: " + pdfFile.isFile());
            System.out.println("File absolute path: " + pdfFile.getAbsolutePath());

            String accessiblePdfPath = pdfPath;

            // Check if file size is 0 (indicates permission issue even if file exists)
            long fileSize = pdfFile.length();
            System.out.println("File size: " + fileSize + " bytes");

            // If we can't access the file directly or file size is 0, try to copy it to our app's directory
            if (!pdfFile.exists() || !pdfFile.canRead() || fileSize == 0) {
                System.out.println("Cannot access original file properly, attempting to copy to accessible location...");
                try {
                    accessiblePdfPath = copyFileToAccessibleLocation(pdfPath);
                    System.out.println("Copied file to: " + accessiblePdfPath);
                } catch (Exception e) {
                    System.out.println("File copy failed, trying to use original path anyway: " + e.getMessage());
                    // If copy fails, try to use the original path anyway
                    accessiblePdfPath = pdfPath;
                }
            }

            // Validate the accessible file
            File accessibleFile = new File(accessiblePdfPath);
            if (!accessibleFile.exists()) {
                throw new SendDataException("PDF file does not exist: " + accessiblePdfPath);
            }
            if (!accessibleFile.canRead()) {
                throw new SendDataException("Cannot read PDF file: " + accessiblePdfPath);
            }

            // Check file size
            long accessibleFileSize = accessibleFile.length();
            System.out.println("Accessible file size: " + accessibleFileSize + " bytes");
            if (accessibleFileSize == 0) {
                throw new SendDataException("PDF file is empty: " + accessiblePdfPath);
            }

            System.out.println("PDF file info - Path: " + accessiblePdfPath + ", Size: " + accessibleFileSize + " bytes");

            // Get Instance of Printer
            ZebraPrinterLinkOs printer = ZebraPrinterFactory.getLinkOsPrinter(connection);

            // Verify Printer Status is Ready
            PrinterStatus printerStatus = printer.getCurrentStatus();
            if (!printerStatus.isReadyToPrint) {
                if (printerStatus.isPaused) {
                    throw new SendDataException("Printer is paused");
                } else if (printerStatus.isHeadOpen) {
                    throw new HeadOpenException();
                } else if (printerStatus.isPaperOut) {
                    throw new PaperOutException();
                }
                return false;
            }

            // Convert PDF to images using PdfUtils
            // Use standard printer width (4 inches = 384 dots at 96 DPI)
            int width = 384;
            int height = 512; // Standard height for thermal printers

            System.out.println("Converting PDF to images...");
            List<ImageData> images = PdfUtils.getImagesFromPdfRenderer(
                    context,
                    accessiblePdfPath,
                    width,
                    height,
                    PdfUtils.Orientation.PORTRAIT,
                    false // Don't write to file, just get bitmaps
            );

            if (images == null || images.isEmpty()) {
                throw new SendDataException("Failed to convert PDF to images - no pages found");
            }

            System.out.println("Successfully converted PDF to " + images.size() + " images");

            // Print each page as an image
            for (int i = 0; i < images.size(); i++) {
                ImageData imageData = images.get(i);
                Bitmap bitmap = imageData.getBitmap();
                if (bitmap != null) {
                    System.out.println("Printing page " + (i + 1) + " - Size: " + bitmap.getWidth() + "x" + bitmap.getHeight());
                    // Create ZebraImageAndroid from bitmap
                    ZebraImageAndroid zebraImage = new ZebraImageAndroid(bitmap);

                    // Print the image
                    printer.printImage(zebraImage, 0, 0, bitmap.getWidth(), bitmap.getHeight(), false);
                } else {
                    System.out.println("Warning: Page " + (i + 1) + " bitmap is null");
                }
            }

            System.out.println("PDF printing completed successfully");
            return true;

        } catch (Exception e) {
            System.err.println("Error in printPdfAsImages: " + e.getMessage());
            e.printStackTrace();
            throw new SendDataException("Failed to print PDF: " + e.getMessage());
        }
    }


    /**
     * Advanced scaling for ZQ320 and ZQ520 printers with 2.84 inch roll
     * Returns the appropriate scale setting based on printer model and paper width
     */
    private String scalePrint(Connection connection) throws ConnectionException {
        try {
            String fullPrinterModel = SGD.GET("device.host_identification", connection);
            String printerModel = fullPrinterModel.substring(0, 5);
            System.out.println("Calculating scale for printer: " + fullPrinterModel);
            
            String scale;
            
            // ZQ320 and ZQ520 specific scaling for 2.84 inch (568 dots) roll
            if (printerModel.equals("ZQ320") || fullPrinterModel.contains("ZQ320")) {
                // ZQ320 Plus at 200 DPI with 2.84 inch roll (568 dots)
                // Use scale-to-fit for best results
                scale = "dither scale-to-fit";
                System.out.println("ZQ320: Using scale-to-fit for 2.84 inch roll");
                
            } else if (printerModel.equals("ZQ520") || fullPrinterModel.contains("ZQ520")) {
                // ZQ520 at 203 DPI with 2.84 inch roll
                // Calculate optimal scale for ZQ520
                double paperWidthInches = 2.84;
                double scaleFactor = (paperWidthInches / 4.0) * 100; // ZQ520 base is 4 inch
                int scaleInt = Math.max(50, Math.min(200, (int) scaleFactor)); // Limit between 50-200%
                
                scale = "dither scale=" + scaleInt + "x" + scaleInt;
                System.out.println("ZQ520: Using manual scale " + scaleInt + "% for 2.84 inch roll");
                
            } else if (printerModel.equals("iMZ22") || printerModel.equals("QLn22") || printerModel.equals("ZD410")) {
                // 2 inch printers - scale up for 2.84 inch roll
                double scaleFactor = (2.84 / 2.0) * 100; // Scale from 2 inch to 2.84 inch
                int scaleInt = (int) scaleFactor;
                scale = "dither scale=" + scaleInt + "x" + scaleInt;
                System.out.println("2-inch printer: Using scale " + scaleInt + "% for 2.84 inch roll");
                
            } else if (printerModel.equals("iMZ32") || printerModel.equals("QLn32") || printerModel.equals("ZQ510")) {
                // 3 inch printers - scale down slightly for 2.84 inch roll
                double scaleFactor = (2.84 / 3.0) * 100; // Scale from 3 inch to 2.84 inch
                int scaleInt = (int) scaleFactor;
                scale = "dither scale=" + scaleInt + "x" + scaleInt;
                System.out.println("3-inch printer: Using scale " + scaleInt + "% for 2.84 inch roll");
                
            } else if (printerModel.equals("QLn42") || printerModel.equals("ZD420") || 
                      printerModel.equals("ZD500") || printerModel.equals("ZT220") || 
                      printerModel.equals("ZT230") || printerModel.equals("ZT410")) {
                // 4 inch printers - scale down for 2.84 inch roll
                double scaleFactor = (2.84 / 4.0) * 100; // Scale from 4 inch to 2.84 inch
                int scaleInt = (int) scaleFactor;
                scale = "dither scale=" + scaleInt + "x" + scaleInt;
                System.out.println("4-inch printer: Using scale " + scaleInt + "% for 2.84 inch roll");
                
            } else if (printerModel.equals("ZT420")) {
                // 6.5 inch printer - scale down significantly for 2.84 inch roll
                double scaleFactor = (2.84 / 6.5) * 100; // Scale from 6.5 inch to 2.84 inch
                int scaleInt = (int) scaleFactor;
                scale = "dither scale=" + scaleInt + "x" + scaleInt;
                System.out.println("6.5-inch printer: Using scale " + scaleInt + "% for 2.84 inch roll");
                
            } else {
                // Unknown printer - use scale-to-fit as safest option
                scale = "dither scale-to-fit";
                System.out.println("Unknown printer: Using scale-to-fit as default");
            }
            
            System.out.println("Final scale setting: " + scale);
            return scale;
            
        } catch (Exception e) {
            System.err.println("Error calculating scale: " + e.getMessage());
            // Fallback to scale-to-fit
            return "dither scale-to-fit";
        }
    }

    /**
     * Diagnose current printer settings to identify issues
     */
    private void diagnosePrinterSettings(Connection connection) {
        try {
            System.out.println("=== PRINTER DIAGNOSIS START ===");
            
            // Get basic printer info
            try {
                String printerModel = SGD.GET("device.host_identification", connection);
                System.out.println("Printer Model: " + printerModel);
            } catch (Exception e) {
                System.out.println("Could not get printer model: " + e.getMessage());
            }
            
            // Check current print width
            try {
                String printWidth = SGD.GET("ezpl.print_width", connection);
                System.out.println("Current Print Width: " + printWidth + " dots");
            } catch (Exception e) {
                System.out.println("Could not get print width: " + e.getMessage());
            }
            
            // Check media type
            try {
                String mediaType = SGD.GET("ezpl.media_type", connection);
                System.out.println("Current Media Type: " + mediaType);
            } catch (Exception e) {
                System.out.println("Could not get media type: " + e.getMessage());
            }
            
            // Check label length
            try {
                String labelLength = SGD.GET("ezpl.label_length", connection);
                System.out.println("Current Label Length: " + labelLength + " dots");
            } catch (Exception e) {
                System.out.println("Could not get label length: " + e.getMessage());
            }
            
            // Check current scaling settings
            try {
                String aplSettings = SGD.GET("apl.settings", connection);
                System.out.println("Current APL Settings: " + aplSettings);
            } catch (Exception e) {
                System.out.println("Could not get APL settings: " + e.getMessage());
            }
            
            // Check print tone
            try {
                String printTone = SGD.GET("print.tone", connection);
                System.out.println("Current Print Tone: " + printTone);
            } catch (Exception e) {
                System.out.println("Could not get print tone: " + e.getMessage());
            }
            
            // Check printer status
            try {
                ZebraPrinterLinkOs printer = ZebraPrinterFactory.getLinkOsPrinter(connection);
                PrinterStatus status = printer.getCurrentStatus();
                System.out.println("Printer Ready: " + status.isReadyToPrint);
                System.out.println("Paper Out: " + status.isPaperOut);
                System.out.println("Head Open: " + status.isHeadOpen);
                System.out.println("Paused: " + status.isPaused);
            } catch (Exception e) {
                System.out.println("Could not get printer status: " + e.getMessage());
            }
            
            System.out.println("=== PRINTER DIAGNOSIS END ===");
            
        } catch (Exception e) {
            System.err.println("Error during printer diagnosis: " + e.getMessage());
        }
    }
    
    /**
     * Verify printer settings after configuration
     */
    private void verifyPrinterSettings(Connection connection) {
        try {
            System.out.println("=== VERIFYING SETTINGS AFTER SETUP ===");
            
            // Verify print width
            try {
                String printWidth = SGD.GET("ezpl.print_width", connection);
                System.out.println("Verified Print Width: " + printWidth + " dots");
                
                int width = Integer.parseInt(printWidth);
                if (width < 550) {
                    System.out.println("WARNING: Print width is less than expected for 2.84 inch paper!");
                    System.out.println("Expected: 568 dots (2.84 inches at 200 DPI)");
                    System.out.println("Actual: " + width + " dots");
                } else {
                    System.out.println("SUCCESS: Print width is correct for 2.84 inch paper!");
                }
            } catch (Exception e) {
                System.out.println("Could not verify print width: " + e.getMessage());
            }
            
            // Verify media type
            try {
                String mediaType = SGD.GET("ezpl.media_type", connection);
                System.out.println("Verified Media Type: " + mediaType);
                if (!mediaType.toLowerCase().contains("continuous")) {
                    System.out.println("WARNING: Media type is not set to continuous roll!");
                }
            } catch (Exception e) {
                System.out.println("Could not verify media type: " + e.getMessage());
            }
            
            // Verify scaling
            try {
                String aplSettings = SGD.GET("apl.settings", connection);
                System.out.println("Verified APL Settings: " + aplSettings);
                if (!aplSettings.toLowerCase().contains("scale")) {
                    System.out.println("WARNING: Scaling may not be configured properly!");
                }
            } catch (Exception e) {
                System.out.println("Could not verify APL settings: " + e.getMessage());
            }
            
            System.out.println("=== VERIFICATION COMPLETE ===");
            
        } catch (Exception e) {
            System.err.println("Error during settings verification: " + e.getMessage());
        }
    }

    /**
     * Setup media dimensions for 2.84 inch roll width, 11 inch height
     * Optimized for ZQ320 Plus printer
     */
    private void setupMediaFor57mmRoll(Connection connection) throws ConnectionException {
        try {
            System.out.println("Setting up media for 2.84 inch roll: 2.84 inch width x 11 inch height");
            
            // Get printer model for specific configuration
            String printerModel = SGD.GET("device.host_identification", connection);
            System.out.println("Configuring media for printer: " + printerModel);
            
            // ZQ320 Plus specific media setup
            if (printerModel.contains("ZQ320")) {
                setupZQ320MediaFor57mmRoll(connection);
            } else {
                setupGenericMediaFor57mmRoll(connection);
            }
            
            System.out.println("Media setup completed for 57mm roll");
            
        } catch (Exception e) {
            System.err.println("Error setting up media: " + e.getMessage());
            e.printStackTrace();
        }
    }
    
    /**
     * ZQ320 Plus specific media setup for 2.84 inch roll
     */
    private void setupZQ320MediaFor57mmRoll(Connection connection) throws ConnectionException {
        try {
            System.out.println("Applying ZQ320 Plus media setup for 2.84 inch roll...");
            
            // Step 1: Set media type to continuous roll
            try {
                SGD.SET("ezpl.media_type", "continuous", connection);
                System.out.println("Set media type to continuous roll");
            } catch (Exception e) {
                System.out.println("Could not set media type: " + e.getMessage());
            }
            
            // Step 2: Set print width for 2.84 inches
            // ZQ320 Plus at 200 DPI: 2.84 inches = 568 dots
            try {
                SGD.SET("ezpl.print_width", "568", connection);
                System.out.println("Set print width to 568 dots (2.84 inches at 200 DPI)");
            } catch (Exception e) {
                System.out.println("Could not set print width: " + e.getMessage());
            }
            
            // Step 3: Set label length for 11 inches
            // 11 inches at 200 DPI = 2200 dots
            try {
                SGD.SET("ezpl.label_length", "2200", connection);
                System.out.println("Set label length to 2200 dots (11 inches at 200 DPI)");
            } catch (Exception e) {
                System.out.println("Could not set label length: " + e.getMessage());
            }
            
            // Step 4: Send ZPL commands for media setup
            try {
                String zplMediaSetup = "^XA" +
                    "^MNN" +             // Media tracking continuous, non-continuous
                    "^PW568" +           // Print width 568 dots (2.84 inches)
                    "^LL2200" +          // Label length 2200 dots (11 inches)
                    "^LH0,0" +           // Label home position
                    "^LT0" +             // Label top position
                    "^CI28" +            // Change international font/encoding
                    "^XZ";
                connection.write(zplMediaSetup.getBytes("UTF-8"));
                System.out.println("Sent ZPL media setup commands for ZQ320 Plus (2.84 inch width)");
            } catch (Exception e) {
                System.out.println("ZPL media setup failed: " + e.getMessage());
            }
            
            // Step 5: Set optimal scaling using scalePrint method
            try {
                String optimalScale = scalePrint(connection);
                SGD.SET("apl.settings", optimalScale, connection);
                System.out.println("Set optimal scaling: " + optimalScale);
            } catch (Exception e) {
                System.out.println("Could not set optimal scaling: " + e.getMessage());
                // Fallback to scale-to-fit
                try {
                    SGD.SET("apl.settings", "dither scale-to-fit", connection);
                    System.out.println("Fallback: Set scale-to-fit");
                } catch (Exception e2) {
                    System.out.println("Fallback scaling also failed: " + e2.getMessage());
                }
            }
            
            // Step 6: Set print quality
            try {
                SGD.SET("print.tone", "15", connection);
                System.out.println("Set print tone to 15 for optimal quality");
            } catch (Exception e) {
                System.out.println("Could not set print tone: " + e.getMessage());
            }
            
        } catch (Exception e) {
            System.err.println("Error in ZQ320 Plus media setup: " + e.getMessage());
        }
    }
    
    /**
     * Generic media setup for other printers
     */
    private void setupGenericMediaFor57mmRoll(Connection connection) throws ConnectionException {
        try {
            System.out.println("Applying generic media setup for 2.84 inch roll...");
            
            // Generic media setup for 2.84 inch width
            SGD.SET("ezpl.media_type", "continuous", connection);
            SGD.SET("ezpl.print_width", "568", connection); // 2.84 inches at 200 DPI
            
            // Use optimal scaling based on printer model
            String optimalScale = scalePrint(connection);
            SGD.SET("apl.settings", optimalScale, connection);
            System.out.println("Applied optimal scaling: " + optimalScale);
            
            String zplSetup = "^XA^MNN^PW568^LL0^LH0,0^XZ";
            connection.write(zplSetup.getBytes("UTF-8"));
            
            System.out.println("Applied generic media setup for 2.84 inch roll");
            
        } catch (Exception e) {
            System.err.println("Error in generic media setup: " + e.getMessage());
        }
    }

    

    /**
     * Public method to apply optimal scaling for ZQ320 and ZQ520 printers
     * Call this method to ensure proper scaling for your specific printer model
     */
    public boolean applyOptimalScaling() throws ConnectionException, SendDataException {
        try {
            System.out.println("=== APPLYING OPTIMAL SCALING ===");
            
            // Get printer model first
            String printerModel = SGD.GET("device.host_identification", connection);
            System.out.println("Applying optimal scaling for: " + printerModel);
            
            // Calculate and apply optimal scale
            String optimalScale = scalePrint(connection);
            SGD.SET("apl.settings", optimalScale, connection);
            
            System.out.println("✅ Successfully applied optimal scaling: " + optimalScale);
            System.out.println("=== SCALING APPLICATION COMPLETE ===");
            
            return true;
            
        } catch (Exception e) {
            System.err.println("❌ Failed to apply optimal scaling: " + e.getMessage());
            throw new SendDataException("Failed to apply optimal scaling: " + e.getMessage());
        }
    }

    /**
     * Save PDF bytes to our app's accessible directory
     */
    private String savePdfBytesToAccessibleLocation(byte[] pdfBytes) throws Exception {
        try {
            // Create a temporary file in our app's cache directory
            File tempDir = new File(context.getCacheDir(), "pdf_print");
            if (!tempDir.exists()) {
                tempDir.mkdirs();
            }

            String fileName = "print_" + System.currentTimeMillis() + ".pdf";
            File tempFile = new File(tempDir, fileName);

            System.out.println("Saving PDF bytes to: " + tempFile.getAbsolutePath());

            // Write PDF bytes to file
            FileOutputStream fos = new FileOutputStream(tempFile);
            fos.write(pdfBytes);
            fos.close();

            // Verify the file was written correctly
            if (!tempFile.exists() || tempFile.length() == 0) {
                throw new Exception("Failed to save PDF bytes to file");
            }

            long fileSize = tempFile.length();
            System.out.println("PDF file saved successfully. Size: " + fileSize + " bytes");

            return tempFile.getAbsolutePath();

        } catch (Exception e) {
            System.err.println("Error saving PDF bytes: " + e.getMessage());
            throw new Exception("Failed to save PDF bytes to accessible location: " + e.getMessage());
        }
    }

    /**
     * Copy a file to our app's accessible directory
     */
    private String copyFileToAccessibleLocation(String originalPath) throws Exception {
        try {
            // Create a temporary file in our app's cache directory
            File tempDir = new File(context.getCacheDir(), "pdf_temp");
            if (!tempDir.exists()) {
                tempDir.mkdirs();
            }

            String fileName = "temp_" + System.currentTimeMillis() + ".pdf";
            File tempFile = new File(tempDir, fileName);

            System.out.println("Copying file from: " + originalPath);
            System.out.println("Copying file to: " + tempFile.getAbsolutePath());

            // Try to copy the file using different methods
            boolean copied = false;

            // Method 1: Try direct file copy
            try {
                File originalFile = new File(originalPath);
                if (originalFile.exists() && originalFile.canRead()) {
                    long originalSize = originalFile.length();
                    System.out.println("Original file size: " + originalSize + " bytes");

                    if (originalSize > 0) {
                        copyFile(originalFile, tempFile);
                        long copiedSize = tempFile.length();
                        System.out.println("Copied file size: " + copiedSize + " bytes");

                        if (copiedSize > 0 && copiedSize == originalSize) {
                            copied = true;
                            System.out.println("File copied successfully using direct method");
                        } else {
                            System.out.println("Direct copy failed - size mismatch or empty copy");
                        }
                    } else {
                        System.out.println("Original file size is 0, skipping direct copy");
                    }
                }
            } catch (Exception e) {
                System.out.println("Direct copy failed: " + e.getMessage());
            }

            // Method 2: Try using content resolver with different URI formats
            if (!copied) {
                String[] uriFormats = {
                        "file://" + originalPath,
                        "content://" + originalPath,
                        originalPath
                };

                for (String uriFormat : uriFormats) {
                    try {
                        System.out.println("Trying content resolver with URI: " + uriFormat);
                        android.net.Uri uri = android.net.Uri.parse(uriFormat);
                        InputStream inputStream = context.getContentResolver().openInputStream(uri);
                        if (inputStream != null) {
                            FileOutputStream outputStream = new FileOutputStream(tempFile);
                            long bytesCopied = copyStream(inputStream, outputStream);
                            inputStream.close();
                            outputStream.close();

                            System.out.println("Content resolver copied " + bytesCopied + " bytes");
                            if (bytesCopied > 0) {
                                copied = true;
                                System.out.println("File copied successfully using content resolver");
                                break;
                            } else {
                                System.out.println("Content resolver copy resulted in 0 bytes");
                            }
                        } else {
                            System.out.println("Content resolver returned null input stream for URI: " + uriFormat);
                        }
                    } catch (Exception e) {
                        System.out.println("Content resolver copy failed for URI " + uriFormat + ": " + e.getMessage());
                    }
                }
            }

            // Method 3: Try using FileInputStream directly
            if (!copied) {
                try {
                    System.out.println("Trying direct FileInputStream method...");
                    FileInputStream fis = new FileInputStream(originalPath);
                    FileOutputStream fos = new FileOutputStream(tempFile);
                    long bytesCopied = copyStream(fis, fos);
                    fis.close();
                    fos.close();

                    System.out.println("FileInputStream copied " + bytesCopied + " bytes");
                    if (bytesCopied > 0) {
                        copied = true;
                        System.out.println("File copied successfully using FileInputStream");
                    } else {
                        System.out.println("FileInputStream copy resulted in 0 bytes");
                    }
                } catch (Exception e) {
                    System.out.println("FileInputStream copy failed: " + e.getMessage());
                }
            }

            if (!copied) {
                throw new Exception("Could not copy file to accessible location");
            }

            // Verify the copied file
            if (!tempFile.exists() || tempFile.length() == 0) {
                throw new Exception("Copied file is empty or does not exist");
            }

            System.out.println("File copied successfully. Size: " + tempFile.length() + " bytes");
            return tempFile.getAbsolutePath();

        } catch (Exception e) {
            System.err.println("Error copying file: " + e.getMessage());
            throw new Exception("Failed to copy file to accessible location: " + e.getMessage());
        }
    }

    private void copyFile(File source, File destination) throws IOException {
        InputStream inputStream = new FileInputStream(source);
        OutputStream outputStream = new FileOutputStream(destination);
        copyStream(inputStream, outputStream);
        inputStream.close();
        outputStream.close();
    }

    private long copyStream(InputStream inputStream, OutputStream outputStream) throws IOException {
        byte[] buffer = new byte[1024];
        int length;
        long totalBytes = 0;
        while ((length = inputStream.read(buffer)) > 0) {
            outputStream.write(buffer, 0, length);
            totalBytes += length;
        }
        return totalBytes;
    }


}
