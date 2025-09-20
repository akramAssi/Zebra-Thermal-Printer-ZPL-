package com.shini.plus.zebra_bluetooth_printer;

import android.graphics.Bitmap;

/**
 * Created by luis901101 on 2020-01-07.
 */
public class ImageData {
    final String path;
    final Bitmap bitmap;
    final int pxWidth;
    final int pxHeight;
    final int inWidth;
    final int inHeight;

    public ImageData(String path, Bitmap bitmap, int pxWidth, int pxHeight, int inWidth, int inHeight)
    {
        this.path = path;
        this.bitmap = bitmap;
        this.pxWidth = pxWidth;
        this.pxHeight = pxHeight;
        this.inWidth = inWidth;
        this.inHeight = inHeight;
    }


    public String getPath() {
        return path;
    }

    public int getInHeight() {
        return inHeight;
    }

    public int getInWidth() {
        return inWidth;
    }

    public int getPxHeight() {
        return pxHeight;
    }

    public int getPxWidth() {
        return pxWidth;
    }

    public Bitmap getBitmap() {
        return bitmap;
    }
}