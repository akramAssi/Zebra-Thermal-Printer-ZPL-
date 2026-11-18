Pod::Spec.new do |s|
  s.name             = 'zebra_bluetooth_printer'
  s.version          = '0.3.0'
  s.summary          = 'Zebra ZPL and PDF printing over Bluetooth.'
  s.description      = 'Connects to a Made-for-iPhone Zebra printer and prints ZPL or PDF.'
  s.homepage         = 'https://github.com/akramAssi/Zebra-Thermal-Printer-ZPL-'
  s.license          = { :file => '../LICENSE' }
  s.author           = { 'Shini' => 'dev@shini.ps' }
  s.source           = { :path => '.' }
  s.source_files     = 'zebra_bluetooth_printer/Sources/zebra_bluetooth_printer/**/*'
  s.dependency 'Flutter'
  s.platform         = :ios, '15.0'
  s.frameworks       = 'ExternalAccessory'
  s.pod_target_xcconfig = { 'DEFINES_MODULE' => 'YES' }
  s.swift_version    = '5.0'
end
