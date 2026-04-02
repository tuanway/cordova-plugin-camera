/*
 Licensed to the Apache Software Foundation (ASF) under one
 or more contributor license agreements.  See the NOTICE file
 distributed with this work for additional information
 regarding copyright ownership.  The ASF licenses this file
 to you under the Apache License, Version 2.0 (the
 "License"); you may not use this file except in compliance
 with the License.  You may obtain a copy of the License at

 http://www.apache.org/licenses/LICENSE-2.0

 Unless required by applicable law or agreed to in writing,
 software distributed under the License is distributed on an
 "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY
 KIND, either express or implied.  See the License for the
 specific language governing permissions and limitations
 under the License.
 */

#import "CDVCamera.h"
#import "CDVJpegHeaderWriter.h"
#import "UIImage+CropScaleOrientation.h"
#import <ImageIO/CGImageProperties.h>
#import <AssetsLibrary/ALAssetRepresentation.h>
#import <AssetsLibrary/AssetsLibrary.h>
#import <AVFoundation/AVFoundation.h>
#import <ImageIO/CGImageSource.h>
#import <ImageIO/CGImageProperties.h>
#import <ImageIO/CGImageDestination.h>
#import <MobileCoreServices/UTCoreTypes.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#import <objc/message.h>
#import <Photos/Photos.h>
#import <PhotosUI/PhotosUI.h>

#ifndef __CORDOVA_4_0_0
    #import <Cordova/NSData+Base64.h>
#endif

#define CDV_PHOTO_PREFIX @"cdv_photo_"

static NSSet* org_apache_cordova_validArrowDirections;

static NSString* toBase64(NSData* data) {
    SEL s1 = NSSelectorFromString(@"cdv_base64EncodedString");
    SEL s2 = NSSelectorFromString(@"base64EncodedString");
    SEL s3 = NSSelectorFromString(@"base64EncodedStringWithOptions:");

    if ([data respondsToSelector:s1]) {
        NSString* (*func)(id, SEL) = (void *)[data methodForSelector:s1];
        return func(data, s1);
    } else if ([data respondsToSelector:s2]) {
        NSString* (*func)(id, SEL) = (void *)[data methodForSelector:s2];
        return func(data, s2);
    } else if ([data respondsToSelector:s3]) {
        NSString* (*func)(id, SEL, NSUInteger) = (void *)[data methodForSelector:s3];
        return func(data, s3, 0);
    } else {
        return nil;
    }
}

static NSString* MIME_PNG     = @"image/png";
static NSString* MIME_JPEG    = @"image/jpeg";

@implementation CDVPictureOptions

+ (instancetype) createFromTakePictureArguments:(CDVInvokedUrlCommand*)command
{
    CDVPictureOptions* pictureOptions = [[CDVPictureOptions alloc] init];

    pictureOptions.quality = [command argumentAtIndex:0 withDefault:@(50)];
    pictureOptions.destinationType = [[command argumentAtIndex:1 withDefault:@(DestinationTypeFileUri)] unsignedIntegerValue];
    pictureOptions.sourceType = [[command argumentAtIndex:2 withDefault:@(UIImagePickerControllerSourceTypeCamera)] unsignedIntegerValue];

    NSNumber* targetWidth = [command argumentAtIndex:3 withDefault:nil];
    NSNumber* targetHeight = [command argumentAtIndex:4 withDefault:nil];
    pictureOptions.targetSize = CGSizeMake(0, 0);
    if ((targetWidth != nil) && (targetHeight != nil)) {
        pictureOptions.targetSize = CGSizeMake([targetWidth floatValue], [targetHeight floatValue]);
    }

    pictureOptions.encodingType = [[command argumentAtIndex:5 withDefault:@(EncodingTypeJPEG)] unsignedIntegerValue];
    pictureOptions.mediaType = [[command argumentAtIndex:6 withDefault:@(MediaTypePicture)] unsignedIntegerValue];
    pictureOptions.allowsEditing = [[command argumentAtIndex:7 withDefault:@(NO)] boolValue];
    pictureOptions.correctOrientation = [[command argumentAtIndex:8 withDefault:@(NO)] boolValue];
    pictureOptions.saveToPhotoAlbum = [[command argumentAtIndex:9 withDefault:@(NO)] boolValue];
    pictureOptions.popoverOptions = [command argumentAtIndex:10 withDefault:nil];
    pictureOptions.cameraDirection = [[command argumentAtIndex:11 withDefault:@(UIImagePickerControllerCameraDeviceRear)] unsignedIntegerValue];
    pictureOptions.allowSelectMultiple = [[command argumentAtIndex:12 withDefault:@(NO)] boolValue];

    pictureOptions.popoverSupported = NO;
    pictureOptions.usesGeolocation = NO;

    return pictureOptions;
}

@end


@interface CDVCamera ()

@property (readwrite, assign) BOOL hasPendingOperation;

- (NSString*)copyFileToTemp:(NSString*)filePath;

@end

@implementation CDVCamera

+ (void)initialize
{
    org_apache_cordova_validArrowDirections = [[NSSet alloc] initWithObjects:[NSNumber numberWithInt:UIPopoverArrowDirectionUp], [NSNumber numberWithInt:UIPopoverArrowDirectionDown], [NSNumber numberWithInt:UIPopoverArrowDirectionLeft], [NSNumber numberWithInt:UIPopoverArrowDirectionRight], [NSNumber numberWithInt:UIPopoverArrowDirectionAny], nil];
}

@synthesize hasPendingOperation, pickerController, locationManager;

- (NSURL*) urlTransformer:(NSURL*)url
{
    NSURL* urlToTransform = url;

    // for backwards compatibility - we check if this property is there
    SEL sel = NSSelectorFromString(@"urlTransformer");
    if ([self.commandDelegate respondsToSelector:sel]) {
        // grab the block from the commandDelegate
        NSURL* (^urlTransformer)(NSURL*) = ((id(*)(id, SEL))objc_msgSend)(self.commandDelegate, sel);
        // if block is not null, we call it
        if (urlTransformer) {
            urlToTransform = urlTransformer(url);
        }
    }

    return urlToTransform;
}

- (BOOL)usesGeolocation
{
    id useGeo = [self.commandDelegate.settings objectForKey:[@"CameraUsesGeolocation" lowercaseString]];
    return [(NSNumber*)useGeo boolValue];
}

- (BOOL)popoverSupported
{
    return (NSClassFromString(@"UIPopoverController") != nil) &&
           (UI_USER_INTERFACE_IDIOM() == UIUserInterfaceIdiomPad);
}

- (void)takePicture:(CDVInvokedUrlCommand*)command
{
    self.hasPendingOperation = YES;
    __weak CDVCamera* weakSelf = self;

    [self.commandDelegate runInBackground:^{
        CDVPictureOptions* pictureOptions = [CDVPictureOptions createFromTakePictureArguments:command];
        pictureOptions.popoverSupported = [weakSelf popoverSupported];
        pictureOptions.usesGeolocation = [weakSelf usesGeolocation];
        pictureOptions.cropToSize = NO;

        BOOL hasCamera = [UIImagePickerController isSourceTypeAvailable:pictureOptions.sourceType];
        if (!hasCamera) {
            NSLog(@"Camera.getPicture: source type %lu not available.", (unsigned long)pictureOptions.sourceType);
            CDVPluginResult* result = [CDVPluginResult resultWithStatus:CDVCommandStatus_ERROR messageAsString:@"No camera available"];
            [weakSelf.commandDelegate sendPluginResult:result callbackId:command.callbackId];
            return;
        }

        // Validate the app has permission to access the camera
        if (pictureOptions.sourceType == UIImagePickerControllerSourceTypeCamera) {
            [AVCaptureDevice requestAccessForMediaType:AVMediaTypeVideo completionHandler:^(BOOL granted)
             {
                 if (!granted)
                 {
                     // Denied; show an alert
                     dispatch_async(dispatch_get_main_queue(), ^{
                         UIAlertController *alertController = [UIAlertController alertControllerWithTitle:[[NSBundle mainBundle] objectForInfoDictionaryKey:@"CFBundleDisplayName"] message:NSLocalizedString(@"Access to the camera has been prohibited; please enable it in the Settings app to continue.", nil) preferredStyle:UIAlertControllerStyleAlert];
                         [alertController addAction:[UIAlertAction actionWithTitle:NSLocalizedString(@"OK", nil) style:UIAlertActionStyleDefault handler:^(UIAlertAction * _Nonnull action) {
                             [weakSelf sendNoPermissionResult:command.callbackId];
                         }]];
                         [alertController addAction:[UIAlertAction actionWithTitle:NSLocalizedString(@"Settings", nil) style:UIAlertActionStyleDefault handler:^(UIAlertAction * _Nonnull action) {
                             [[UIApplication sharedApplication] openURL:[NSURL URLWithString:UIApplicationOpenSettingsURLString] options:@{} completionHandler:nil];
                             [weakSelf sendNoPermissionResult:command.callbackId];
                         }]];
                         [weakSelf.viewController presentViewController:alertController animated:YES completion:nil];
                     });
                 } else {
                     dispatch_async(dispatch_get_main_queue(), ^{
                         [weakSelf showCameraPicker:command.callbackId withOptions:pictureOptions];
                     });
                 }
             }];
        } else {
            // On iOS 14+, PHPickerViewController handles its own permissions,
            // so we only need to check permissions for older iOS or when using UIImagePickerController
            if (@available(iOS 14, *)) {
                if (pictureOptions.sourceType == UIImagePickerControllerSourceTypePhotoLibrary ||
                    pictureOptions.sourceType == UIImagePickerControllerSourceTypeSavedPhotosAlbum) {
                    // PHPicker will handle its own permission UI, proceed directly
                    [weakSelf showCameraPicker:command.callbackId withOptions:pictureOptions];
                    return;
                }
            }
            [weakSelf options:pictureOptions requestPhotoPermissions:^(BOOL granted) {
                if (!granted) {
                    // Denied; show an alert
                    dispatch_async(dispatch_get_main_queue(), ^{
                        UIAlertController *alertController = [UIAlertController alertControllerWithTitle:[[NSBundle mainBundle] objectForInfoDictionaryKey:@"CFBundleDisplayName"] message:NSLocalizedString(@"Access to the camera roll has been prohibited; please enable it in the Settings to continue.", nil) preferredStyle:UIAlertControllerStyleAlert];
                        [alertController addAction:[UIAlertAction actionWithTitle:NSLocalizedString(@"OK", nil) style:UIAlertActionStyleDefault handler:^(UIAlertAction * _Nonnull action) {
                            [weakSelf sendNoPermissionResult:command.callbackId];
                        }]];
                        [alertController addAction:[UIAlertAction actionWithTitle:NSLocalizedString(@"Settings", nil) style:UIAlertActionStyleDefault handler:^(UIAlertAction * _Nonnull action) {
                            [[UIApplication sharedApplication] openURL:[NSURL URLWithString:UIApplicationOpenSettingsURLString] options:@{} completionHandler:nil];
                            [weakSelf sendNoPermissionResult:command.callbackId];
                        }]];
                        [weakSelf.viewController presentViewController:alertController animated:YES completion:nil];
                    });
                } else {
                    dispatch_async(dispatch_get_main_queue(), ^{
                        [weakSelf showCameraPicker:command.callbackId withOptions:pictureOptions];
                    });
                }
            }];
        }
    }];
}

- (void)showCameraPicker:(NSString*)callbackId withOptions:(CDVPictureOptions*)pictureOptions
{
    // Use PHPickerViewController for photo library on iOS 14+
    if (@available(iOS 14, *)) {
        // sourceType is PHOTOLIBRARY
        if (pictureOptions.sourceType == UIImagePickerControllerSourceTypePhotoLibrary ||
            // sourceType is SAVEDPHOTOALBUM (same as PHOTOLIBRARY)
            pictureOptions.sourceType == UIImagePickerControllerSourceTypeSavedPhotosAlbum) {
            [self showPHPicker:callbackId withOptions:pictureOptions];
            return;
        }
    }

    // Use UIImagePickerController for camera or as image picker for iOS older than 14
    // UIImagePickerController must be created and presented on the main thread.
    dispatch_async(dispatch_get_main_queue(), ^{
        CDVCameraPicker* cameraPicker = [CDVCameraPicker createFromPictureOptions:pictureOptions];
        self.pickerController = cameraPicker;

        cameraPicker.delegate = self;
        cameraPicker.callbackId = callbackId;
        // we need to capture this state for memory warnings that dealloc this object
        cameraPicker.webView = self.webView;

        // If a popover is already open, close it; we only want one at a time.
        if (([[self pickerController] pickerPopoverController] != nil) && [[[self pickerController] pickerPopoverController] isPopoverVisible]) {
            [[[self pickerController] pickerPopoverController] dismissPopoverAnimated:YES];
            [[[self pickerController] pickerPopoverController] setDelegate:nil];
            [[self pickerController] setPickerPopoverController:nil];
        }

        if ([self popoverSupported] && (pictureOptions.sourceType != UIImagePickerControllerSourceTypeCamera)) {
            if (cameraPicker.pickerPopoverController == nil) {
                cameraPicker.pickerPopoverController = [[NSClassFromString(@"UIPopoverController") alloc] initWithContentViewController:cameraPicker];
            }
            [self displayPopover:pictureOptions.popoverOptions];
            self.hasPendingOperation = NO;
        } else {
            cameraPicker.modalPresentationStyle = UIModalPresentationCurrentContext;
            [self.viewController presentViewController:cameraPicker animated:YES completion:^{
                self.hasPendingOperation = NO;
            }];
        }
    });
}

- (void)sendNoPermissionResult:(NSString*)callbackId
{
    CDVPluginResult* result = [CDVPluginResult resultWithStatus:CDVCommandStatus_ERROR messageAsString:@"has no access to camera"];   // error callback expects string ATM

    [self.commandDelegate sendPluginResult:result callbackId:callbackId];

    self.hasPendingOperation = NO;
    self.pickerController = nil;
}

// Since iOS 14, we can use PHPickerViewController to select images from the photo library
#if __IPHONE_OS_VERSION_MAX_ALLOWED >= 140000 // Always true on XCode12+
- (void)showPHPicker:(NSString*)callbackId withOptions:(CDVPictureOptions*)pictureOptions API_AVAILABLE(ios(14))
{
    // PHPicker must be created and presented on the main thread.
    dispatch_async(dispatch_get_main_queue(), ^{
        // Using [PHPickerConfiguration init] instead of
        // [PHPickerConfiguration initWithPhotoLibrary:[PHPhotoLibrary sharedPhotoLibrary]]
        // is more open and lets the picker return items that aren't PHAssets, like cloud/shared providers,
        // but will not return asset identifiers.
        PHPickerConfiguration *config = [[PHPickerConfiguration alloc] init];

        // Configure filter based on media type
        // Images
        if (pictureOptions.mediaType == MediaTypePicture) {
            config.filter = [PHPickerFilter imagesFilter];

            // Videos
        } else if (pictureOptions.mediaType == MediaTypeVideo) {
            config.filter = [PHPickerFilter videosFilter];

            // Images and videos
        } else if (pictureOptions.mediaType == MediaTypeAll) {
            config.filter = [PHPickerFilter anyFilterMatchingSubfilters:@[
                [PHPickerFilter imagesFilter],
                [PHPickerFilter videosFilter]
            ]];
        }

        if (pictureOptions.allowSelectMultiple) {
            config.selectionLimit = 0; // 0 means unlimited selection
        } else {
            config.selectionLimit = 1;
        }

        // PHPickerConfigurationAssetRepresentationModeCurrent:
        // A mode that uses the current representation to avoid transcoding, if possible.
        // This means PHPicker tries to give you a representation already available without
        // re-encoding. That usually is the stored file on device (e.g., HEIC/JPEG),
        // but if the asset is only in iCloud or already has a cached "current" rendition,
        // you might get that cached representation instead of downloading the original.
        // This plugin supports only JPEG and PNG currently and will convert the
        // image later in processImage: to the requested format.
        config.preferredAssetRepresentationMode = PHPickerConfigurationAssetRepresentationModeCurrent;

        PHPickerViewController *picker = [[PHPickerViewController alloc] initWithConfiguration:config];
        picker.delegate = self;

        // Store callback ID and options in picker with objc_setAssociatedObject
        // PHPickerViewController's delegate method picker:didFinishPicking: only gives you back the picker instance
        // and the results array. It doesn't carry arbitrary context. By associating the callbackId and pictureOptions
        // with the picker, you can retrieve them later inside the delegate method
        objc_setAssociatedObject(picker, "callbackId", callbackId, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        objc_setAssociatedObject(picker, "pictureOptions", pictureOptions, OBJC_ASSOCIATION_RETAIN_NONATOMIC);

        [self.viewController presentViewController:picker animated:YES completion:^{
            self.hasPendingOperation = NO;
        }];
    });
}

// PHPickerViewControllerDelegate method (implementing without formal protocol conformance)
- (void)picker:(PHPickerViewController*)picker didFinishPicking:(NSArray<PHPickerResult*>*)results API_AVAILABLE(ios(14))
{
    NSString *callbackId = objc_getAssociatedObject(picker, "callbackId");
    CDVPictureOptions *pictureOptions = objc_getAssociatedObject(picker, "pictureOptions");

    __weak CDVCamera* weakSelf = self;

    [picker dismissViewControllerAnimated:YES completion:^{
        if (results.count == 0) {
            // User cancelled
            CDVPluginResult* result = [CDVPluginResult resultWithStatus:CDVCommandStatus_ERROR messageAsString:@"No Image Selected"];
            [weakSelf.commandDelegate sendPluginResult:result callbackId:callbackId];
            weakSelf.hasPendingOperation = NO;
            return;
        }

        // Handle multiple image selection
        if (pictureOptions.allowSelectMultiple) {
            [weakSelf processMultiplePHPickerImages:results
                                       callbackId:callbackId
                                          options:pictureOptions];
        } else {
            // Handle single image selection (existing behavior)
            PHPickerResult *pickerResult = results.firstObject;

            // Check if it's a video
            if ([pickerResult.itemProvider hasItemConformingToTypeIdentifier:UTTypeMovie.identifier]) {
                // loadFileRepresentationForTypeIdentifier returns an url which will be gone after the completion handler returns,
                // so we need to copy the video to a temporary location, which can be accessed later
                [pickerResult.itemProvider loadFileRepresentationForTypeIdentifier:UTTypeMovie.identifier
                                                                 completionHandler:^(NSURL * _Nullable url, NSError * _Nullable error) {
                    if (error) {
                        NSLog(@"CDVCamera: Failed to load video: %@", [error localizedDescription]);
                        CDVPluginResult* result = [CDVPluginResult resultWithStatus:CDVCommandStatus_IO_EXCEPTION
                                                                    messageAsString:[NSString stringWithFormat:@"Failed to load video: %@", [error localizedDescription]]];
                        [weakSelf.commandDelegate sendPluginResult:result callbackId:callbackId];
                        weakSelf.hasPendingOperation = NO;
                        return;
                    }

                    // Copy video to a temporary location, so it can be accessed after this completion handler returns
                    NSString* tempVideoPath = [weakSelf copyFileToTemp:[url path]];

                    // Send Cordova plugin result back
                    CDVPluginResult* result = nil;

                    if (tempVideoPath == nil) {
                        result = [CDVPluginResult resultWithStatus:CDVCommandStatus_IO_EXCEPTION
                                                    messageAsString:@"Failed to copy video file to temporary location"];
                    } else {
                        result = [CDVPluginResult resultWithStatus:CDVCommandStatus_OK messageAsString:tempVideoPath];
                    }

                    [weakSelf.commandDelegate sendPluginResult:result callbackId:callbackId];
                    weakSelf.hasPendingOperation = NO;
                }];

                // Handle image
            } else if ([pickerResult.itemProvider hasItemConformingToTypeIdentifier:UTTypeImage.identifier]) {
                // Load image data for the NSItemProvider
                [pickerResult.itemProvider loadDataRepresentationForTypeIdentifier:UTTypeImage.identifier
                                                                 completionHandler:^(NSData * _Nullable imageData, NSError * _Nullable error) {
                    if (error) {
                        CDVPluginResult* result = [CDVPluginResult resultWithStatus:CDVCommandStatus_ERROR
                                                                    messageAsString:[error localizedDescription]];
                        [weakSelf.commandDelegate sendPluginResult:result callbackId:callbackId];
                        weakSelf.hasPendingOperation = NO;
                        return;
                    }

                    [weakSelf processPHPickerImage:[UIImage imageWithData:imageData]
                                          metadata:[weakSelf convertImageMetadata:imageData]
                                        callbackId:callbackId
                                           options:pictureOptions];
                }];
            }
        }
    }];
}

/**
    Prepares the image and metadata obtained from PHPickerImageViewController which will be processed in
    resultForImage:. After that CDVPluginResult is returned.
*/
- (void)processPHPickerImage:(UIImage*)image
                     metadata:(NSDictionary*)metadata
                   callbackId:(NSString*)callbackId
                      options:(CDVPictureOptions*)options API_AVAILABLE(ios(14))
{
    // To shrink the file size, only selected meta data like EXIF, TIFF, and GPS is used,
    // which will be stored in self.metadata, which is set to the image in resultForImage:
    // This code replicates the logic from processImage: for the UIImagePickerController
    if (metadata.count > 0) {
        self.metadata = [NSMutableDictionary dictionary];

        NSDictionary *exif = metadata[(NSString *)kCGImagePropertyExifDictionary];
        if (exif.count > 0) {
            self.metadata[(NSString *)kCGImagePropertyExifDictionary] = [exif mutableCopy];
        }

        NSDictionary *tiff = metadata[(NSString *)kCGImagePropertyTIFFDictionary];
        if (tiff.count > 0) {
            self.metadata[(NSString *)kCGImagePropertyTIFFDictionary] = [tiff mutableCopy];
        }

        NSDictionary *gps = metadata[(NSString *)kCGImagePropertyGPSDictionary];
        if (gps.count > 0) {
            self.metadata[(NSString *)kCGImagePropertyGPSDictionary] = [gps mutableCopy];
        }
    }

    // Mimic the info dictionary which would be created by UIImagePickerController
    // Add image, which will be used in retrieveImage: to get the image and do processing
    NSMutableDictionary *info = [@{UIImagePickerControllerOriginalImage : image} mutableCopy];

    // Add metadata if available
    if (metadata.count > 0) {
        // This is not used anywhere and can be removed
        info[UIImagePickerControllerMediaMetadata] = metadata;
    }

    // Return Cordova result to WebView
    // Needed weakSelf for completion block
    __weak CDVCamera* weakSelf = self;

    // Process and return result
    [self resultForImage:options info:info completion:^(CDVPluginResult* pluginResult) {
        [weakSelf.commandDelegate sendPluginResult:pluginResult callbackId:callbackId];
        weakSelf.hasPendingOperation = NO;
        weakSelf.pickerController = nil;
    }];
}

/**
    Prepares multiple images and metadata obtained from PHPickerViewController and returns them as an array.
*/
- (void)processMultiplePHPickerImages:(NSArray<PHPickerResult*>*)results
                           callbackId:(NSString*)callbackId
                              options:(CDVPictureOptions*)options API_AVAILABLE(ios(14))
{
    // Create a mutable array to store the results
    NSMutableArray* resultsArray = [NSMutableArray arrayWithCapacity:results.count];

    // Process each result
    [self processNextImage:results
                   atIndex:0
             resultsArray:resultsArray
                callbackId:callbackId
                   options:options];
}

- (void)processNextImage:(NSArray<PHPickerResult*>*)results
                 atIndex:(NSUInteger)index
            resultsArray:(NSMutableArray*)resultsArray
              callbackId:(NSString*)callbackId
                 options:(CDVPictureOptions*)options API_AVAILABLE(ios(14))
{
    // Base case: if we've processed all images, return the results
    if (index >= results.count) {
        CDVPluginResult* result = [CDVPluginResult resultWithStatus:CDVCommandStatus_OK messageAsArray:resultsArray];
        [self.commandDelegate sendPluginResult:result callbackId:callbackId];
        self.hasPendingOperation = NO;
        self.pickerController = nil;
        return;
    }

    PHPickerResult *pickerResult = results[index];
    __weak CDVCamera* weakSelf = self;

    // Check if it's a video
    if ([pickerResult.itemProvider hasItemConformingToTypeIdentifier:UTTypeMovie.identifier]) {
        [pickerResult.itemProvider loadFileRepresentationForTypeIdentifier:UTTypeMovie.identifier
                                                         completionHandler:^(NSURL * _Nullable url, NSError * _Nullable error) {
            if (error) {
                NSLog(@"CDVCamera: Failed to load video: %@", [error localizedDescription]);
                // Skip this video and continue with next
                [weakSelf processNextImage:results
                                   atIndex:index + 1
                              resultsArray:resultsArray
                                 callbackId:callbackId
                                    options:options];
                return;
            }

            NSString* tempVideoPath = [weakSelf copyFileToTemp:[url path]];

            if (tempVideoPath != nil) {
                [resultsArray addObject:tempVideoPath];
            }

            // Continue with next image
            [weakSelf processNextImage:results
                               atIndex:index + 1
                          resultsArray:resultsArray
                            callbackId:callbackId
                               options:options];
        }];

    // Handle image
    } else if ([pickerResult.itemProvider hasItemConformingToTypeIdentifier:UTTypeImage.identifier]) {
        [pickerResult.itemProvider loadDataRepresentationForTypeIdentifier:UTTypeImage.identifier
                                                         completionHandler:^(NSData * _Nullable imageData, NSError * _Nullable error) {
            if (error) {
                NSLog(@"CDVCamera: Failed to load image: %@", [error localizedDescription]);
                // Skip this image and continue with next
                [weakSelf processNextImage:results
                                   atIndex:index + 1
                              resultsArray:resultsArray
                                 callbackId:callbackId
                                    options:options];
                return;
            }

            UIImage* image = [UIImage imageWithData:imageData];
            NSDictionary* metadata = [weakSelf convertImageMetadata:imageData];

            // Process the image
            [weakSelf processPHPickerImageForArray:image
                                          metadata:metadata
                                      resultsArray:resultsArray
                                          callbackId:callbackId
                                             options:options
                                             results:results
                                             atIndex:index];
        }];
    }
}

- (void)processPHPickerImageForArray:(UIImage*)image
                            metadata:(NSDictionary*)metadata
                        resultsArray:(NSMutableArray*)resultsArray
                          callbackId:(NSString*)callbackId
                             options:(CDVPictureOptions*)options
                             results:(NSArray<PHPickerResult*>*)results
                             atIndex:(NSUInteger)index API_AVAILABLE(ios(14))
{
    // To shrink the file size, only selected meta data like EXIF, TIFF, and GPS is used
    if (metadata.count > 0) {
        self.metadata = [NSMutableDictionary dictionary];

        NSDictionary *exif = metadata[(NSString *)kCGImagePropertyExifDictionary];
        if (exif.count > 0) {
            self.metadata[(NSString *)kCGImagePropertyExifDictionary] = [exif mutableCopy];
        }

        NSDictionary *tiff = metadata[(NSString *)kCGImagePropertyTIFFDictionary];
        if (tiff.count > 0) {
            self.metadata[(NSString *)kCGImagePropertyTIFFDictionary] = [tiff mutableCopy];
        }

        NSDictionary *gps = metadata[(NSString *)kCGImagePropertyGPSDictionary];
        if (gps.count > 0) {
            self.metadata[(NSString *)kCGImagePropertyGPSDictionary] = [gps mutableCopy];
        }
    }

    // Mimic the info dictionary which would be created by UIImagePickerController
    NSMutableDictionary *info = [@{UIImagePickerControllerOriginalImage : image} mutableCopy];

    if (metadata.count > 0) {
        info[UIImagePickerControllerMediaMetadata] = metadata;
    }

    __weak CDVCamera* weakSelf = self;

    [self resultForImage:options info:info completion:^(CDVPluginResult* pluginResult) {
        if ([pluginResult.status intValue] == CDVCommandStatus_OK) {
            [resultsArray addObject:pluginResult.message];
        }

        // Continue with next image
        [weakSelf processNextImage:results
                           atIndex:index + 1
                      resultsArray:resultsArray
                        callbackId:callbackId
                           options:options];
    }];
}
#endif

- (void)repositionPopover:(CDVInvokedUrlCommand*)command
{
    if (([[self pickerController] pickerPopoverController] != nil) && [[[self pickerController] pickerPopoverController] isPopoverVisible]) {

        [[[self pickerController] pickerPopoverController] dismissPopoverAnimated:NO];

        NSDictionary* options = [command argumentAtIndex:0 withDefault:nil];
        [self displayPopover:options];
    }
}

- (NSInteger)integerValueForKey:(NSDictionary*)dict key:(NSString*)key defaultValue:(NSInteger)defaultValue
{
    NSInteger value = defaultValue;

    NSNumber* val = [dict valueForKey:key];  // value is an NSNumber

    if (val != nil) {
        value = [val integerValue];
    }
    return value;
}

- (void)displayPopover:(NSDictionary*)options
{
    NSInteger x = 0;
    NSInteger y = 32;
    NSInteger width = 320;
    NSInteger height = 480;
    UIPopoverArrowDirection arrowDirection = UIPopoverArrowDirectionAny;

    if (options) {
        x = [self integerValueForKey:options key:@"x" defaultValue:0];
        y = [self integerValueForKey:options key:@"y" defaultValue:32];
        width = [self integerValueForKey:options key:@"width" defaultValue:320];
        height = [self integerValueForKey:options key:@"height" defaultValue:480];
        arrowDirection = [self integerValueForKey:options key:@"arrowDir" defaultValue:UIPopoverArrowDirectionAny];
        if (![org_apache_cordova_validArrowDirections containsObject:[NSNumber numberWithUnsignedInteger:arrowDirection]]) {
            arrowDirection = UIPopoverArrowDirectionAny;
        }
    }

    [[[self pickerController] pickerPopoverController] setDelegate:self];
    [[[self pickerController] pickerPopoverController] presentPopoverFromRect:CGRectMake(x, y, width, height)
                                                                 inView:[self.webView superview]
                                               permittedArrowDirections:arrowDirection
                                                               animated:YES];
}

- (void)navigationController:(UINavigationController *)navigationController willShowViewController:(UIViewController *)viewController animated:(BOOL)animated
{
    if([navigationController isKindOfClass:[UIImagePickerController class]]){
        
        // If popoverWidth and popoverHeight are specified and are greater than 0, then set popover size, else use apple's default popoverSize
        NSDictionary* options = self.pickerController.pictureOptions.popoverOptions;
        if(options) {
            NSInteger popoverWidth = [self integerValueForKey:options key:@"popoverWidth" defaultValue:0];
            NSInteger popoverHeight = [self integerValueForKey:options key:@"popoverHeight" defaultValue:0];
            if(popoverWidth > 0 && popoverHeight > 0)
            {
                [viewController setPreferredContentSize:CGSizeMake(popoverWidth,popoverHeight)];
            }
        }
        
        
        UIImagePickerController* cameraPicker = (UIImagePickerController*)navigationController;

        if(![cameraPicker.mediaTypes containsObject:(NSString*)kUTTypeImage]){
            [viewController.navigationItem setTitle:NSLocalizedString(@"Videos", nil)];
        }
    }
}

- (void)cleanup:(CDVInvokedUrlCommand*)command
{
    // empty the tmp directory
    NSFileManager* fileMgr = [[NSFileManager alloc] init];
    NSError* err = nil;
    BOOL hasErrors = NO;

    // clear contents of NSTemporaryDirectory
    NSString* tempDirectoryPath = NSTemporaryDirectory();
    NSDirectoryEnumerator* directoryEnumerator = [fileMgr enumeratorAtPath:tempDirectoryPath];
    NSString* fileName = nil;
    BOOL result;

    while ((fileName = [directoryEnumerator nextObject])) {
        // only delete the files we created
        if (![fileName hasPrefix:CDV_PHOTO_PREFIX]) {
            continue;
        }
        NSString* filePath = [tempDirectoryPath stringByAppendingPathComponent:fileName];
        result = [fileMgr removeItemAtPath:filePath error:&err];
        if (!result && err) {
            NSLog(@"Failed to delete: %@ (error: %@)", filePath, err);
            hasErrors = YES;
        }
    }

    CDVPluginResult* pluginResult;
    if (hasErrors) {
        pluginResult = [CDVPluginResult resultWithStatus:CDVCommandStatus_IO_EXCEPTION messageAsString:@"One or more files failed to be deleted."];
    } else {
        pluginResult = [CDVPluginResult resultWithStatus:CDVCommandStatus_OK];
    }
    [self.commandDelegate sendPluginResult:pluginResult callbackId:command.callbackId];
}

- (void)popoverControllerDidDismissPopover:(id)popoverController
{
    UIPopoverController* pc = (UIPopoverController*)popoverController;

    [pc dismissPopoverAnimated:YES];
    pc.delegate = nil;
    if (self.pickerController && self.pickerController.callbackId && self.pickerController.pickerPopoverController) {
        self.pickerController.pickerPopoverController = nil;
        NSString* callbackId = self.pickerController.callbackId;
        CDVPluginResult* result = [CDVPluginResult resultWithStatus:CDVCommandStatus_ERROR messageAsString:@"no image selected"];   // error callback expects string ATM
        [self.commandDelegate sendPluginResult:result callbackId:callbackId];
    }
    self.hasPendingOperation = NO;
}

- (NSString*) getMimeForEncoding:(CDVEncodingType) encoding {
    switch (encoding) {
        case EncodingTypePNG: return MIME_PNG;
        case EncodingTypeJPEG:
        default:
            return MIME_JPEG;
    }
}

- (NSString*) formatAsDataURI:(NSData*) data withMIME:(NSString*) mime {
    NSString* base64 = toBase64(data);
    
    if (base64 == nil) {
        return nil;
    }
    
    return [NSString stringWithFormat:@"data:%@;base64,%@", mime, base64];
}

- (NSString*) processImageAsDataUri:(UIImage*) image info:(NSDictionary*) info options:(CDVPictureOptions*) options
{
    NSString* mime = nil;
    NSData* data = [self processImage: image info: info options: options outMime: &mime];
    
    return [self formatAsDataURI: data withMIME: mime];
}

- (NSData*) processImage:(UIImage*) image info:(NSDictionary*) info options:(CDVPictureOptions*) options
{
    return [self processImage:image  info: info options: options outMime: nil];
}

- (NSData*) processImage:(UIImage*)image info:(NSDictionary*)info options:(CDVPictureOptions*)options outMime:(NSString**) outMime
{
    NSData* data = nil;

    switch (options.encodingType) {
        case EncodingTypePNG:
            data = UIImagePNGRepresentation(image);
            if (outMime != nil) *outMime = MIME_PNG;
            break;
        case EncodingTypeJPEG:
        {
            if (outMime != nil) *outMime = MIME_JPEG;
            if ((options.allowsEditing == NO) && (options.targetSize.width <= 0) && (options.targetSize.height <= 0) && (options.correctOrientation == NO) && (([options.quality integerValue] == 100) || (options.sourceType != UIImagePickerControllerSourceTypeCamera))){
                // use image unedited as requested , don't resize
                data = UIImageJPEGRepresentation(image, 1.0);
            } else {
                data = UIImageJPEGRepresentation(image, [options.quality floatValue] / 100.0f);
            }

            if (pickerController.sourceType == UIImagePickerControllerSourceTypeCamera) {
                if (options.usesGeolocation) {
                    NSDictionary* controllerMetadata = [info objectForKey:@"UIImagePickerControllerMediaMetadata"];
                    if (controllerMetadata) {
                        self.data = data;
                        self.metadata = [[NSMutableDictionary alloc] init];

                        NSMutableDictionary* EXIFDictionary = [[controllerMetadata objectForKey:(NSString*)kCGImagePropertyExifDictionary]mutableCopy];
                        if (EXIFDictionary)    {
                            [self.metadata setObject:EXIFDictionary forKey:(NSString*)kCGImagePropertyExifDictionary];
                        }

                        if (IsAtLeastiOSVersion(@"8.0")) {
                            [[self locationManager] performSelector:NSSelectorFromString(@"requestWhenInUseAuthorization") withObject:nil afterDelay:0];
                        }
                        [[self locationManager] startUpdatingLocation];
                    }
                data = nil;
                }
            } else if (pickerController.sourceType == UIImagePickerControllerSourceTypePhotoLibrary) {
                PHAsset* asset = [info objectForKey:@"UIImagePickerControllerPHAsset"];
                NSDictionary* controllerMetadata = [self getImageMetadataFromAsset:asset];

                self.data = data;
                if (controllerMetadata) {
                    self.metadata = [[NSMutableDictionary alloc] init];

                    NSMutableDictionary* EXIFDictionary = [[controllerMetadata objectForKey:(NSString*)kCGImagePropertyExifDictionary]mutableCopy];
                    if (EXIFDictionary)    {
                        [self.metadata setObject:EXIFDictionary forKey:(NSString*)kCGImagePropertyExifDictionary];
                    }
                    NSMutableDictionary* TIFFDictionary = [[controllerMetadata objectForKey:(NSString*)kCGImagePropertyTIFFDictionary
                    ]mutableCopy];
                    if (TIFFDictionary)    {
                        [self.metadata setObject:TIFFDictionary forKey:(NSString*)kCGImagePropertyTIFFDictionary];
                    }
                    NSMutableDictionary* GPSDictionary = [[controllerMetadata objectForKey:(NSString*)kCGImagePropertyGPSDictionary
]mutableCopy];
                    if (GPSDictionary)    {
                        [self.metadata setObject:GPSDictionary forKey:(NSString*)kCGImagePropertyGPSDictionary
];
                    }
                }
            }

        }
            break;
        default:
            break;
    };
    
    
    return data;
}

/* --------------------------------------------------------------
-- get the metadata of the image from a PHAsset
-------------------------------------------------------------- */
- (NSDictionary*)getImageMetadataFromAsset:(PHAsset*)asset {

    if(asset == nil) {
        return nil;
    }

    // get photo info from this asset
    __block NSDictionary *dict = nil;
    PHImageRequestOptions *imageRequestOptions = [[PHImageRequestOptions alloc] init];
    imageRequestOptions.synchronous = YES;
    [[PHImageManager defaultManager]
     requestImageDataForAsset:asset
     options:imageRequestOptions
     resultHandler: ^(NSData *imageData, NSString *dataUTI, UIImageOrientation orientation, NSDictionary *info) {
        dict = [self convertImageMetadata:imageData]; // as this imageData is in NSData format so we need a method to convert this NSData into NSDictionary
     }];
    return dict;
}

-(NSDictionary*)convertImageMetadata:(NSData*)imageData {
    CGImageSourceRef imageSource = CGImageSourceCreateWithData((__bridge CFDataRef)(imageData), NULL);
    if (imageSource) {
        NSDictionary *options = @{(NSString *)kCGImageSourceShouldCache : [NSNumber numberWithBool:NO]};
        CFDictionaryRef imageProperties = CGImageSourceCopyPropertiesAtIndex(imageSource, 0, (__bridge CFDictionaryRef)options);
        if (imageProperties) {
            NSDictionary *metadata = (__bridge NSDictionary *)imageProperties;
            CFRelease(imageProperties);
            CFRelease(imageSource);
            NSLog(@"Metadata of selected image%@", metadata);// image metadata after converting NSData into NSDictionary
            return metadata;
        }
        CFRelease(imageSource);
    }

    NSLog(@"Can't read image metadata");
    return nil;
}

- (void)options:(CDVPictureOptions*)options requestPhotoPermissions:(void (^)(BOOL auth))completion
{
    if((unsigned long)options.sourceType == 1){
        completion(YES);
    }
    else{
        PHAuthorizationStatus status = [PHPhotoLibrary authorizationStatus];

        // Check for authorized status (works on all iOS versions)
        if (status == PHAuthorizationStatusAuthorized) {
            completion(YES);
            return;
        }

        // Check for limited access status (iOS 14+ only)
        // Using integer comparison to avoid compilation errors on pre-iOS 14 SDKs
        // PHAuthorizationStatus enum: 0=NotDetermined, 1=Restricted, 2=Denied, 3=Authorized, 4=Limited
        if (@available(iOS 14.0, *)) {
            if ((NSInteger)status == 4) {  // PHAuthorizationStatusLimited
                completion(YES);
                return;
            }
        }

        // For NotDetermined status, request authorization
        if (status == PHAuthorizationStatusNotDetermined) {
            [PHPhotoLibrary requestAuthorization:^(PHAuthorizationStatus authorizationStatus) {
                if (authorizationStatus == PHAuthorizationStatusAuthorized) {
                    completion(YES);
                } else if (@available(iOS 14.0, *)) {
                    // Check for limited access status (value 4)
                    if ((NSInteger)authorizationStatus == 4) {  // PHAuthorizationStatusLimited
                        completion(YES);
                    } else {
                        completion(NO);
                    }
                } else {
                    completion(NO);
                }
            }];
            return;
        }

        // All other cases (denied, restricted, limited on pre-iOS 14)
        completion(NO);
    }

}

- (NSString*)tempFilePath:(NSString*)extension
{
    NSString* docsPath = [NSTemporaryDirectory()stringByStandardizingPath];
    // unique file name
    NSTimeInterval timeStamp = [[NSDate date] timeIntervalSince1970];
    NSNumber *timeStampObj = [NSNumber numberWithDouble: timeStamp];
    NSString* filePath = [NSString stringWithFormat:@"%@/%@%ld.%@", docsPath, CDV_PHOTO_PREFIX, [timeStampObj longValue], extension];

    return filePath;
}

- (UIImage*)retrieveImage:(NSDictionary*)info options:(CDVPictureOptions*)options
{
    // get the image
    UIImage* image = nil;
    if (options.allowsEditing && [info objectForKey:UIImagePickerControllerEditedImage]) {
        image = [info objectForKey:UIImagePickerControllerEditedImage];
    } else {
        image = [info objectForKey:UIImagePickerControllerOriginalImage];
    }

    if (options.correctOrientation) {
        image = [image imageCorrectedForCaptureOrientation];
    }

    UIImage* scaledImage = nil;

    if ((options.targetSize.width > 0) && (options.targetSize.height > 0)) {
        // if cropToSize, resize image and crop to target size, otherwise resize to fit target without cropping
        if (options.cropToSize) {
            scaledImage = [image imageByScalingAndCroppingForSize:options.targetSize];
        } else {
            scaledImage = [image imageByScalingNotCroppingForSize:options.targetSize];
        }
    }

    return (scaledImage == nil ? image : scaledImage);
}

- (void)resultForImage:(CDVPictureOptions*)options info:(NSDictionary*)info completion:(void (^)(CDVPluginResult* res))completion
{
    CDVPluginResult* result = nil;
    BOOL saveToPhotoAlbum = options.saveToPhotoAlbum;
    UIImage* image = nil;

    switch (options.destinationType) {
        case DestinationTypeDataUrl:
        {
            image = [self retrieveImage:info options:options];
            NSString* data = [self processImageAsDataUri:image info:info options:options];
            if (data)  {
                result = [CDVPluginResult resultWithStatus:CDVCommandStatus_OK messageAsString: data];
            }
        }
            break;
        default: // DestinationTypeFileUri
        {
            image = [self retrieveImage:info options:options];
            NSData* data = [self processImage:image info:info options:options];
            
            if (data) {
                if (pickerController.sourceType == UIImagePickerControllerSourceTypePhotoLibrary) {
                    NSMutableData *imageDataWithExif = [NSMutableData data];
                    if (self.metadata) {
                        CGImageSourceRef sourceImage = CGImageSourceCreateWithData((__bridge CFDataRef)self.data, NULL);
                        CFStringRef sourceType = CGImageSourceGetType(sourceImage);

                        CGImageDestinationRef destinationImage = CGImageDestinationCreateWithData((__bridge CFMutableDataRef)imageDataWithExif, sourceType, 1, NULL);
                        CGImageDestinationAddImageFromSource(destinationImage, sourceImage, 0, (__bridge CFDictionaryRef)self.metadata);
                        CGImageDestinationFinalize(destinationImage);

                        CFRelease(sourceImage);
                        CFRelease(destinationImage);
                    } else {
                        imageDataWithExif = [self.data mutableCopy];
                    }

                    NSError* err = nil;
                    NSString* extension = options.encodingType == EncodingTypePNG ? @"png":@"jpg";
                    NSString* filePath = [self tempFilePath:extension];

                    // save file
                    if (![imageDataWithExif writeToFile:filePath options:NSAtomicWrite error:&err]) {
                        result = [CDVPluginResult resultWithStatus:CDVCommandStatus_IO_EXCEPTION messageAsString:[err localizedDescription]];
                    }
                    else {
                        result = [CDVPluginResult resultWithStatus:CDVCommandStatus_OK messageAsString:[[self urlTransformer:[NSURL fileURLWithPath:filePath]] absoluteString]];
                    }
                    
                } else if (pickerController.sourceType != UIImagePickerControllerSourceTypeCamera || !options.usesGeolocation) {
                    // No need to save file if usesGeolocation is true since it will be saved after the location is tracked
                    NSString* extension = options.encodingType == EncodingTypePNG? @"png" : @"jpg";
                    NSString* filePath = [self tempFilePath:extension];
                    NSError* err = nil;

                    // save file
                    if (![data writeToFile:filePath options:NSAtomicWrite error:&err]) {
                        result = [CDVPluginResult resultWithStatus:CDVCommandStatus_IO_EXCEPTION messageAsString:[err localizedDescription]];
                    } else {
                        result = [CDVPluginResult resultWithStatus:CDVCommandStatus_OK messageAsString:[[self urlTransformer:[NSURL fileURLWithPath:filePath]] absoluteString]];
                    }
                }

            }
        }
            break;
    };

    if (saveToPhotoAlbum && image) {
        UIImageWriteToSavedPhotosAlbum(image, nil, nil, nil);
    }

    completion(result);
}

- (CDVPluginResult*)resultForVideo:(NSDictionary*)info
{
    NSString* moviePath = [[info objectForKey:UIImagePickerControllerMediaURL] absoluteString];
    // On iOS 13 the movie path becomes inaccessible, create and return a copy
    if (IsAtLeastiOSVersion(@"13.0")) {
        moviePath = [self createTmpVideo:[[info objectForKey:UIImagePickerControllerMediaURL] path]];
    }
    return [CDVPluginResult resultWithStatus:CDVCommandStatus_OK messageAsString:moviePath];
}

- (NSString *) createTmpVideo:(NSString *) moviePath {
    NSString* moviePathExtension = [moviePath pathExtension];
    NSString* copyMoviePath = [self tempFilePath:moviePathExtension];
    NSFileManager* fileMgr = [[NSFileManager alloc] init];
    NSError *error;
    [fileMgr copyItemAtPath:moviePath toPath:copyMoviePath error:&error];
    return [[NSURL fileURLWithPath:copyMoviePath] absoluteString];
}

- (NSString*)copyFileToTemp:(NSString*)filePath {
    NSString* fileExtension = [filePath pathExtension];
    NSString* tempPath = [self tempFilePath:fileExtension];
    NSFileManager* fileMgr = [[NSFileManager alloc] init];
    NSError *error;
    [fileMgr copyItemAtPath:filePath toPath:tempPath error:&error];
    if (error) {
        NSLog(@"CDVCamera: Failed to copy file to temp: %@", [error localizedDescription]);
        return nil;
    }
    return tempPath;
}

- (void)imagePickerController:(UIImagePickerController*)picker didFinishPickingMediaWithInfo:(NSDictionary*)info
{
    __weak CDVCameraPicker* cameraPicker = (CDVCameraPicker*)picker;
    __weak CDVCamera* weakSelf = self;

    dispatch_block_t invoke = ^(void) {
        __block CDVPluginResult* result = nil;

        NSString* mediaType = [info objectForKey:UIImagePickerControllerMediaType];
        if ([mediaType isEqualToString:(NSString*)kUTTypeImage]) {
            [weakSelf resultForImage:cameraPicker.pictureOptions info:info completion:^(CDVPluginResult* res) {
                if (![self usesGeolocation] || picker.sourceType != UIImagePickerControllerSourceTypeCamera) {
                    [weakSelf.commandDelegate sendPluginResult:res callbackId:cameraPicker.callbackId];
                    weakSelf.hasPendingOperation = NO;
                    weakSelf.pickerController = nil;
                }
            }];
        }
        else {
            result = [weakSelf resultForVideo:info];
            [weakSelf.commandDelegate sendPluginResult:result callbackId:cameraPicker.callbackId];
            weakSelf.hasPendingOperation = NO;
            weakSelf.pickerController = nil;
        }
    };

    if (cameraPicker.pictureOptions.popoverSupported && (cameraPicker.pickerPopoverController != nil)) {
        [cameraPicker.pickerPopoverController dismissPopoverAnimated:YES];
        cameraPicker.pickerPopoverController.delegate = nil;
        cameraPicker.pickerPopoverController = nil;
        invoke();
    } else {
        [[cameraPicker presentingViewController] dismissViewControllerAnimated:YES completion:invoke];
    }
}

// older api calls newer didFinishPickingMediaWithInfo
- (void)imagePickerController:(UIImagePickerController*)picker didFinishPickingImage:(UIImage*)image editingInfo:(NSDictionary*)editingInfo
{
    NSDictionary* imageInfo = [NSDictionary dictionaryWithObject:image forKey:UIImagePickerControllerOriginalImage];

    [self imagePickerController:picker didFinishPickingMediaWithInfo:imageInfo];
}

- (void)imagePickerControllerDidCancel:(UIImagePickerController*)picker
{
    __weak CDVCameraPicker* cameraPicker = (CDVCameraPicker*)picker;
    __weak CDVCamera* weakSelf = self;

    dispatch_block_t invoke = ^ (void) {
        CDVPluginResult* result;
        if (picker.sourceType == UIImagePickerControllerSourceTypeCamera && [AVCaptureDevice authorizationStatusForMediaType:AVMediaTypeVideo] != AVAuthorizationStatusAuthorized) {
            result = [CDVPluginResult resultWithStatus:CDVCommandStatus_ERROR messageAsString:@"has no access to camera"];
        } else {
            result = [CDVPluginResult resultWithStatus:CDVCommandStatus_ERROR messageAsString:@"No Image Selected"];
        }


        [weakSelf.commandDelegate sendPluginResult:result callbackId:cameraPicker.callbackId];

        weakSelf.hasPendingOperation = NO;
        weakSelf.pickerController = nil;
    };

    [[cameraPicker presentingViewController] dismissViewControllerAnimated:YES completion:invoke];
}

- (CLLocationManager*)locationManager
{
    if (locationManager != nil) {
        return locationManager;
    }

    locationManager = [[CLLocationManager alloc] init];
    [locationManager setDesiredAccuracy:kCLLocationAccuracyNearestTenMeters];
    [locationManager setDelegate:self];

    return locationManager;
}

- (void)locationManager:(CLLocationManager*)manager didUpdateToLocation:(CLLocation*)newLocation fromLocation:(CLLocation*)oldLocation
{
    if (locationManager == nil) {
        return;
    }

    [self.locationManager stopUpdatingLocation];
    self.locationManager = nil;

    NSMutableDictionary *GPSDictionary = [[NSMutableDictionary dictionary] init];

    CLLocationDegrees latitude  = newLocation.coordinate.latitude;
    CLLocationDegrees longitude = newLocation.coordinate.longitude;

    // latitude
    if (latitude < 0.0) {
        latitude = latitude * -1.0f;
        [GPSDictionary setObject:@"S" forKey:(NSString*)kCGImagePropertyGPSLatitudeRef];
    } else {
        [GPSDictionary setObject:@"N" forKey:(NSString*)kCGImagePropertyGPSLatitudeRef];
    }
    [GPSDictionary setObject:[NSNumber numberWithFloat:latitude] forKey:(NSString*)kCGImagePropertyGPSLatitude];

    // longitude
    if (longitude < 0.0) {
        longitude = longitude * -1.0f;
        [GPSDictionary setObject:@"W" forKey:(NSString*)kCGImagePropertyGPSLongitudeRef];
    }
    else {
        [GPSDictionary setObject:@"E" forKey:(NSString*)kCGImagePropertyGPSLongitudeRef];
    }
    [GPSDictionary setObject:[NSNumber numberWithFloat:longitude] forKey:(NSString*)kCGImagePropertyGPSLongitude];

    // altitude
    CGFloat altitude = newLocation.altitude;
    if (!isnan(altitude)){
        if (altitude < 0) {
            altitude = -altitude;
            [GPSDictionary setObject:@"1" forKey:(NSString *)kCGImagePropertyGPSAltitudeRef];
        } else {
            [GPSDictionary setObject:@"0" forKey:(NSString *)kCGImagePropertyGPSAltitudeRef];
        }
        [GPSDictionary setObject:[NSNumber numberWithFloat:altitude] forKey:(NSString *)kCGImagePropertyGPSAltitude];
    }

    // Time and date
    NSDateFormatter *formatter = [[NSDateFormatter alloc] init];
    [formatter setDateFormat:@"HH:mm:ss.SSSSSS"];
    [formatter setTimeZone:[NSTimeZone timeZoneWithAbbreviation:@"UTC"]];
    [GPSDictionary setObject:[formatter stringFromDate:newLocation.timestamp] forKey:(NSString *)kCGImagePropertyGPSTimeStamp];
    [formatter setDateFormat:@"yyyy:MM:dd"];
    [GPSDictionary setObject:[formatter stringFromDate:newLocation.timestamp] forKey:(NSString *)kCGImagePropertyGPSDateStamp];

    [self.metadata setObject:GPSDictionary forKey:(NSString *)kCGImagePropertyGPSDictionary];
    [self imagePickerControllerReturnImageResult];
}

- (void)locationManager:(CLLocationManager*)manager didFailWithError:(NSError*)error
{
    if (locationManager == nil) {
        return;
    }

    [self.locationManager stopUpdatingLocation];
    self.locationManager = nil;

    [self imagePickerControllerReturnImageResult];
}

- (void)imagePickerControllerReturnImageResult
{
    CDVPictureOptions* options = self.pickerController.pictureOptions;
    CDVPluginResult* result = nil;
   
    NSMutableData *imageDataWithExif = [NSMutableData data];

    if (self.metadata) {
        NSData* dataCopy = [self.data mutableCopy];
        CGImageSourceRef sourceImage = CGImageSourceCreateWithData((__bridge CFDataRef)dataCopy, NULL);
        CFStringRef sourceType = CGImageSourceGetType(sourceImage);

        CGImageDestinationRef destinationImage = CGImageDestinationCreateWithData((__bridge CFMutableDataRef)imageDataWithExif, sourceType, 1, NULL);
        CGImageDestinationAddImageFromSource(destinationImage, sourceImage, 0, (__bridge CFDictionaryRef)self.metadata);
        CGImageDestinationFinalize(destinationImage);

        dataCopy = nil;
        CFRelease(sourceImage);
        CFRelease(destinationImage);
    } else {
        imageDataWithExif = [self.data mutableCopy];
    }

    switch (options.destinationType) {
        case DestinationTypeDataUrl:
        {
            NSString* mime = [self getMimeForEncoding: self.pickerController.pictureOptions.encodingType];
            NSString* uri = [self formatAsDataURI: self.data withMIME: mime];
            result = [CDVPluginResult resultWithStatus:CDVCommandStatus_OK messageAsString: uri];
        }
            break;
        default: // DestinationTypeFileUri
        {
            NSError* err = nil;
            NSString* extension = self.pickerController.pictureOptions.encodingType == EncodingTypePNG ? @"png":@"jpg";
            NSString* filePath = [self tempFilePath:extension];

            // save file
            if (![self.data writeToFile:filePath options:NSAtomicWrite error:&err]) {
                result = [CDVPluginResult resultWithStatus:CDVCommandStatus_IO_EXCEPTION messageAsString:[err localizedDescription]];
            }
            else {
                result = [CDVPluginResult resultWithStatus:CDVCommandStatus_OK messageAsString:[[self urlTransformer:[NSURL fileURLWithPath:filePath]] absoluteString]];
            }
        }
            break;
    };

    if (result) {
        [self.commandDelegate sendPluginResult:result callbackId:self.pickerController.callbackId];
    }

    self.hasPendingOperation = NO;
    self.pickerController = nil;
    self.data = nil;
    self.metadata = nil;
    imageDataWithExif = nil;
    if (options.saveToPhotoAlbum) {
        UIImageWriteToSavedPhotosAlbum([[UIImage alloc] initWithData:self.data], nil, nil, nil);
    }
}

@end

@implementation CDVCameraPicker

- (BOOL)prefersStatusBarHidden
{
    return YES;
}

- (UIViewController*)childViewControllerForStatusBarHidden
{
    return nil;
}

- (void)viewWillAppear:(BOOL)animated
{
    SEL sel = NSSelectorFromString(@"setNeedsStatusBarAppearanceUpdate");
    if ([self respondsToSelector:sel]) {
        [self performSelector:sel withObject:nil afterDelay:0];
    }

    [super viewWillAppear:animated];
}

+ (instancetype) createFromPictureOptions:(CDVPictureOptions*)pictureOptions;
{
    CDVCameraPicker* cameraPicker = [[CDVCameraPicker alloc] init];
    cameraPicker.pictureOptions = pictureOptions;
    cameraPicker.sourceType = pictureOptions.sourceType;
    cameraPicker.allowsEditing = pictureOptions.allowsEditing;

    if (cameraPicker.sourceType == UIImagePickerControllerSourceTypeCamera) {
        // We only allow taking pictures (no video) in this API.
        cameraPicker.mediaTypes = @[(NSString*)kUTTypeImage];
        // We can only set the camera device if we're actually using the camera.
        cameraPicker.cameraDevice = pictureOptions.cameraDirection;
    } else if (pictureOptions.mediaType == MediaTypeAll) {
        cameraPicker.mediaTypes = [UIImagePickerController availableMediaTypesForSourceType:cameraPicker.sourceType];
    } else {
        NSArray* mediaArray = @[(NSString*)(pictureOptions.mediaType == MediaTypeVideo ? kUTTypeMovie : kUTTypeImage)];
        cameraPicker.mediaTypes = mediaArray;
    }

    return cameraPicker;
}

@end
