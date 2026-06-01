// Ensure SHOULD_COMPILE_LOOKIN_SERVER is defined when imported as a module
#ifndef SHOULD_COMPILE_LOOKIN_SERVER
#define SHOULD_COMPILE_LOOKIN_SERVER 1
#endif

#ifdef SHOULD_COMPILE_LOOKIN_SERVER

//
//  Peertalk.h
//  Peertalk
//
//  Created by Marek Cirkos on 12/04/2016.
//
//



#import <Foundation/Foundation.h>

//! Project version number for Peertalk.
FOUNDATION_EXPORT double PeertalkVersionNumber;

//! Project version string for Peertalk.
FOUNDATION_EXPORT const unsigned char PeertalkVersionString[];

// In this header, you should import all the public headers of your framework using statements like #import <Peertalk/PublicHeader.h>


#import "XP_PTPrivate.h"
#import "XP_PTChannel.h"
#import "XP_PTProtocol.h"
#import "XP_PTUSBHub.h"

#endif /* SHOULD_COMPILE_LOOKIN_SERVER */
