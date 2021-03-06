//
//  mqttitudeViewController.h
//  mqttitude
//
//  Created by Christoph Krey on 17.08.13.
//  Copyright (c) 2013 Christoph Krey. All rights reserved.
//

#import <UIKit/UIKit.h>
#import <CoreLocation/CoreLocation.h>
#import <MapKit/MapKit.h>
#import "MQTTSession.h"
#import "Connection.h"
#import "Annotations.h"

@interface mqttitudeViewController : UIViewController <MKMapViewDelegate, AnnotationsDelegate>

@end
