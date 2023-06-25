package com.shini.plus.zebra_bluetooth_printer.exception;

public class HeadOpenException extends RuntimeException {

    public HeadOpenException() {
        super("Printer Head is Open");
    }
}

