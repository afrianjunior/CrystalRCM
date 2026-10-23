#ifndef CrystalRCM_DX_Bridging_Header_h
#define CrystalRCM_DX_Bridging_Header_h

#import <IOKit/IOCFPlugIn.h>
#import <IOKit/usb/IOUSBLib.h>
#import <IOKit/usb/USB.h>

static inline CFUUIDRef get_kIOUSBInterfaceUserClientTypeID(void) {
    return kIOUSBInterfaceUserClientTypeID;
}

static inline CFUUIDBytes get_kIOUSBInterfaceInterfaceIDBytes(void) {
    return CFUUIDGetUUIDBytes(kIOUSBInterfaceInterfaceID);
}
#endif /* CrystalRCM_DX_Bridging_Header_h */
