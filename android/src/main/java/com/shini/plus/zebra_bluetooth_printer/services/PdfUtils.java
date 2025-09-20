package com.shini.plus.zebra_bluetooth_printer.services;



import android.content.Context;
import android.graphics.Bitmap;
import android.graphics.Color;
import android.graphics.Matrix;
import android.graphics.RectF;
import android.graphics.pdf.PdfRenderer;
import android.net.Uri;
import android.os.ParcelFileDescriptor;

import com.shini.plus.zebra_bluetooth_printer.ImageData;

import java.io.File;
import java.io.FileOutputStream;
import java.io.FileInputStream;
import java.io.IOException;
import java.util.ArrayList;
import java.util.List;

/**
 * Created by luis901101 on 2020-01-07.
 */
public class PdfUtils
{
    public enum Orientation {
        PORTRAIT, LANDSCAPE
    }
    public static List<ImageData> getImagesFromPdf(Context context, String filePath, int width, int height, Orientation orientation, boolean writeToFile) throws Exception
    {
        // Use the PdfRenderer method instead of the non-existent vudroid library
        return getImagesFromPdfRenderer(context, filePath, width, height, orientation, writeToFile);
    }

    /**
     * Convert PDF bytes to images using Android's PdfRenderer
     * This method bypasses file access restrictions by working directly with bytes
     */
    public static List<ImageData> getImagesFromPdfBytes(Context context, byte[] pdfBytes, int width, int height, Orientation orientation, boolean writeToFile) throws Exception
    {
        List<ImageData> list = new ArrayList<>();
        
        try {
            // Check Android version
            if (android.os.Build.VERSION.SDK_INT < android.os.Build.VERSION_CODES.LOLLIPOP) {
                throw new Exception("PDF rendering requires Android Lollipop (API 21) or higher. Current API: " + android.os.Build.VERSION.SDK_INT);
            }
            
            // Validate PDF bytes
            if (pdfBytes == null || pdfBytes.length == 0) {
                throw new Exception("PDF bytes are null or empty");
            }
            
            System.out.println("PdfUtils - Processing PDF bytes: " + pdfBytes.length + " bytes");
            
            // Create a temporary file to write the PDF bytes
            File tempFile = new File(context.getCacheDir(), "temp_pdf_" + System.currentTimeMillis() + ".pdf");
            FileOutputStream fos = new FileOutputStream(tempFile);
            fos.write(pdfBytes);
            fos.close();
            
            System.out.println("PdfUtils - Created temporary file: " + tempFile.getAbsolutePath());
            
            // Use the existing PdfRenderer method with the temporary file
            List<ImageData> result = getImagesFromPdfRenderer(context, tempFile.getAbsolutePath(), width, height, orientation, writeToFile);
            
            // Clean up temporary file
            if (tempFile.exists()) {
                tempFile.delete();
                System.out.println("PdfUtils - Cleaned up temporary file");
            }
            
            return result;
            
        } catch (Exception e) {
            System.err.println("Error in getImagesFromPdfBytes: " + e.getMessage());
            e.printStackTrace();
            throw new Exception("Failed to process PDF bytes: " + e.getMessage(), e);
        }
    }

    public static List<ImageData> getImagesFromPdfRenderer(Context context, String filePath, int width, int height, Orientation orientation, boolean writeToFile) throws Exception
    {
        List<ImageData> list = new ArrayList<>();
        
        try {
            // Check Android version
            if (android.os.Build.VERSION.SDK_INT < android.os.Build.VERSION_CODES.LOLLIPOP) {
                throw new Exception("PDF rendering requires Android Lollipop (API 21) or higher. Current API: " + android.os.Build.VERSION.SDK_INT);
            }
            
            // Validate file
            File file = new File(filePath);
            System.out.println("PdfUtils - Checking file: " + filePath);
            System.out.println("PdfUtils - File exists: " + file.exists());
            System.out.println("PdfUtils - File can read: " + file.canRead());
            System.out.println("PdfUtils - File size: " + file.length() + " bytes");
            
            if (!file.exists()) {
                throw new Exception("PDF file does not exist: " + filePath);
            }
            
            System.out.println("Opening PDF file: " + filePath);
            
            // Try different URI methods for file access
            Uri fileUri;
            try {
                // First try with file:// URI
                fileUri = Uri.fromFile(file);
                System.out.println("Using file:// URI: " + fileUri.toString());
            } catch (Exception e) {
                System.out.println("Failed to create file:// URI, trying alternative method");
                // Try with file path directly
                fileUri = Uri.parse("file://" + filePath);
                System.out.println("Using parsed URI: " + fileUri.toString());
            }
            
            final ParcelFileDescriptor pfdPdf = context.getContentResolver()
                    .openFileDescriptor(fileUri, "r");

            if(pfdPdf == null) {
                throw new Exception("Cannot open PDF file - ParcelFileDescriptor is null");
            }
            
            System.out.println("Creating PdfRenderer...");
            PdfRenderer pdf = new PdfRenderer(pfdPdf);
            
            int pageCount = pdf.getPageCount();
            System.out.println("PDF has " + pageCount + " pages");
            
            if (pageCount == 0) {
                pdf.close();
                throw new Exception("PDF file has no pages");
            }
            
            for(int i = 0; i < pageCount; ++i) {
                System.out.println("Processing page " + (i + 1) + " of " + pageCount);
                PdfRenderer.Page page = pdf.openPage(i);
                
                Bitmap bitmap = Bitmap.createBitmap(width, height, Bitmap.Config.ARGB_8888);
                bitmap.eraseColor(Color.WHITE);
                
                page.render(bitmap, null, null, PdfRenderer.Page.RENDER_MODE_FOR_PRINT);
                page.close();

                Matrix matrix = new Matrix();
                matrix.postRotate(orientation == Orientation.LANDSCAPE ? 90 : 0);
                Bitmap rotatedBitmap = Bitmap.createBitmap(bitmap, 0, 0, bitmap.getWidth(), bitmap.getHeight(), matrix, true);

                File outputFile = new File(context.getExternalCacheDir(), "/pages/"+"page-"+i+".jpg");
                if(writeToFile){
                    outputFile.getParentFile().mkdirs();
                    outputFile.createNewFile();
                    FileOutputStream outputStream = new FileOutputStream(outputFile);

                    // a bit long running
                    rotatedBitmap.compress(Bitmap.CompressFormat.JPEG, 100, outputStream);

                    outputStream.close();
                }
                list.add(new ImageData(outputFile.getAbsolutePath(), rotatedBitmap, 0, 0, 0, 0));
            }
            pdf.close();
            System.out.println("Successfully processed " + list.size() + " pages");
            
        } catch (Exception e) {
            System.err.println("Error in getImagesFromPdfRenderer: " + e.getMessage());
            e.printStackTrace();
            throw new Exception("Failed to process PDF: " + e.getMessage(), e);
        }
        
        return list;
    }

    /** Returns the printWidth of the pdf page in inches for scaling later
     * PdfRenderer is only available for devices running Android Lollipop or newer
     */
    public static Integer getPageWidth(Context context, String filePath) throws IOException
    {
        final ParcelFileDescriptor pfdPdf = context.getContentResolver()
                .openFileDescriptor(Uri.parse("file://" + filePath), "r");
        if(pfdPdf == null) return 0;
        if (android.os.Build.VERSION.SDK_INT >= android.os.Build.VERSION_CODES.LOLLIPOP) {
            PdfRenderer pdf = new PdfRenderer(pfdPdf);
            PdfRenderer.Page page = pdf.openPage(0);
            int pixWidth = page.getWidth();
            return pixWidth / 72;
        }
        return 0;
    }
}