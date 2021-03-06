//
//  Connection.m
//  mqttitude
//
//  Created by Christoph Krey on 25.08.13.
//  Copyright (c) 2013 Christoph Krey. All rights reserved.
//

#import "Connection.h"

@interface Connection()

@property (nonatomic) NSInteger state;

@property (strong, nonatomic) NSTimer *reconnectTimer;
@property (nonatomic) float reconnectTime;

@property (strong, nonatomic) MQTTSession *session;
@property (strong, nonatomic) NSMutableArray *fifo;

@property (strong, nonatomic) NSString *lastHost;
@property (nonatomic) NSInteger lastPort;
@property (nonatomic) BOOL lastTls;
@property (nonatomic) BOOL lastAuth;
@property (strong, nonatomic) NSString *lastUser;
@property (strong, nonatomic) NSString *lastPass;

@property (strong, nonatomic) NSData *lastWill;
@property (strong, nonatomic) NSString *lastWillTopic;
@property (nonatomic) BOOL lastClean;
@property (nonatomic) BOOL lastWillRetainFlag;
@property (nonatomic) NSInteger lastKeepalive;
@property (nonatomic) NSInteger lastWillQos;

@property (strong, nonatomic, readwrite) NSDate *lastConnected;
@property (strong, nonatomic, readwrite) NSDate *lastClosed;
@property (strong, nonatomic, readwrite) NSDate *lastError;
@property (nonatomic, readwrite) NSError *lastErrorCode;

@end

#define RECONNECT_TIMER 1.0
#define RECONNECT_TIMER_MAX 512.0

/*
 * Connection represents the MQTT connection in the MQTTitude context - state Matrix w.i.p
 *
 * Current State        Event           Action              Next State
 * ---------------------------------------------------------------------------
 *
 * Starting             connectTo:                          Connecting
 *                      sendData:       store & connect     Connecting
 *                      subscribe:
 *                      unsubscribe:
 *                      disconnect:
 *                      Connected
 *                      Received
 *                      Closed
 *                      Error
 *                      Timer
 *                      <auto>
 *
 * Connecting           connectTo:
 *                      sendData:       store
 *                      subscribe:
 *                      unsubscribe:
 *                      disconnect:
 *                      Connected       -                   Connected
 *                      Received
 *                      Closed          -                   Closed
 *                      Error           -                   Error
 *                      Timer
 *                      <auto>
 *
 * Connected            connectTo:
 *                      sendData:       send
 *                      subscribe:
 *                      unsubscribe:
 *                      disconnect:     unsub & disc        Closing
 *                      Connected
 *                      Received
 *                      Closed
 *                      Error                               Error
 *                      Timer
 *                      <auto>
 *
 * Closing              connectTo:                          Connecting
 *                      sendData:       store & connect     Connecting
 *                      subscribe:
 *                      unsubscribe:
 *                      disconnect:
 *                      Connected
 *                      Received
 *                      Closed          -                   Closed
 *                      Error
 *                      Timer
 *                      <auto>
 *
 * Closed               connectTo:
 *                      sendData:
 *                      subscribe:
 *                      unsubscribe:
 *                      disconnect:
 *                      Connected
 *                      Received
 *                      Closed
 *                      Error
 *                      Timer
 *                      <auto>          -                   Starting
 *
 * Error                connectTo:
 *                      sendData:
 *                      subscribe:
 *                      unsubscribe:
 *                      disconnect:
 *                      Connected
 *                      Received
 *                      Closed
 *                      Error
 *                      Timer           reconnect           Connecting
 *                      <auto>
 *
 * ---------------------------------------------------------------------------
 *
 * Connection implements a fifo queue to store messages if the connection is not in Connected state
 *
 * - if sendData is called and status is not connected, data is stored in fifo queue and a connect attempt to the last connection is made
 *
 * Connection automatically reconnects after error using an increasing reconnect timer of 1, 2, 4, ..., 512 seconds
 *
 * Connection records the timestamps of the last successful connect, the last close, the last error and the last error code
 *
 * Connection provides a class method dataToString (missing in IOS)
 *
 */

@implementation Connection

- (id)init
{
#ifdef DEBUG
    NSLog(@"Connection init");
#endif

    self = [super init];
    self.state = state_starting;
    self.lastError = [NSDate dateWithTimeIntervalSince1970:0];
    self.lastConnected = [NSDate dateWithTimeIntervalSince1970:0];
    self.lastClosed = [NSDate dateWithTimeIntervalSince1970:0];
    return self;
}

/*
 * externally visible methods
 */

#define OTHERS @"#"
#define MQTT_KEEPALIVE 60

- (void)connectTo:(NSString *)host port:(NSInteger)port tls:(BOOL)tls keepalive:(NSInteger)keepalive auth:(BOOL)auth user:(NSString *)user pass:(NSString *)pass willTopic:(NSString *)willTopic will:(NSData *)will willQos:(NSInteger)willQos willRetainFlag:(BOOL)willRetainFlag
{
#ifdef DEBUG
    NSLog(@"Connection connectTo: %@:%@@%@:%d %@ (%d) / %@ %@ q%d r%d",
          auth ? user : @"",
          auth ? pass : @"",
          host,
          port,
          tls ? @"TLS" : @"PLAIN",
          keepalive,
          willTopic,
          [Connection dataToString:will],
          willQos,
          willRetainFlag
          );
#endif

    self.lastHost = host;
    self.lastPort = port;
    self.lastTls = tls;
    self.lastKeepalive = keepalive;
    self.lastAuth = auth;
    self.lastUser = user;
    self.lastPass = pass;
    self.lastWillTopic = willTopic;
    self.lastWill = will;
    self.lastWillQos = willQos;
    self.lastWillRetainFlag = willRetainFlag;
    
    self.reconnectTime = RECONNECT_TIMER;
    
    [self connectToInternal];
}

- (void)sendData:(NSData *)data topic:(NSString *)topic qos:(NSInteger)qos retain:(BOOL)retainFlag
{
#ifdef DEBUG
    NSLog(@"Connection sendData:%@ %@ q%d r%d", topic, [Connection dataToString:data], qos, retainFlag);
#endif

    if (self.state != state_connected) {
#ifdef DEBUG
        NSLog(@"Connection intoFifo");
#endif
        NSDictionary *parameters = @{
                                     @"DATA": data,
                                     @"TOPIC": topic,
                                     @"QOS": [NSString stringWithFormat:@"%d",  qos],
                                     @"RETAINFLAG": [NSString stringWithFormat:@"%d",  retainFlag]
                                     };
        [self.fifo addObject:parameters];
        [self connectToLast];
    } else {
#ifdef DEBUG
        NSLog(@"Connection send");
#endif
        [self.session publishData:data
                          onTopic:topic
                           retain:retainFlag
                              qos:qos];
    }
}

- (void)disconnect
{
#ifdef DEBUG
    NSLog(@"Connection disconnect:");
#endif

    if (self.state == state_connected) {
        self.state = state_closing;
        [self.session unsubscribeTopic:[[NSUserDefaults standardUserDefaults] stringForKey:@"subscription_preference"]];
        [self.session close];
    } else {
        self.state = state_starting;
        NSLog(@"MQTTitude not connected, can't close");
    }
}

- (void)subscribe:(NSString *)topic qos:(NSInteger)qos
{
#ifdef DEBUG
    NSLog(@"Connection subscribe:%@ (%d)", topic, qos);
#endif

    [self.session subscribeToTopic:topic atLevel:qos];
}

- (void)unsubscribe:(NSString *)topic
{
#ifdef DEBUG
    NSLog(@"Connection unsubscribe:%@", topic);
#endif

    [self.session unsubscribeTopic:topic];
}

#pragma mark - MQtt Callback methods

- (void)handleEvent:(MQTTSession *)session event:(MQTTSessionEvent)eventCode error:(NSError *)error
{
#ifdef DEBUG
    const NSDictionary *events = @{
                                   @(MQTTSessionEventConnected): @"connected",
                                   @(MQTTSessionEventConnectionRefused): @"connection refused",
                                   @(MQTTSessionEventConnectionClosed): @"connection closed",
                                   @(MQTTSessionEventConnectionError): @"connection error",
                                   @(MQTTSessionEventProtocolError): @"protocoll error"
                                   };
    NSLog(@"Connection MQTT eventCode: %@ (%d) %@", events[@(eventCode)], eventCode, error);
#endif
    [self.reconnectTimer invalidate];
    switch (eventCode) {
        case MQTTSessionEventConnected:
        {
            self.lastConnected = [NSDate date];
            self.state = state_connected;
            [self.session subscribeToTopic:[[NSUserDefaults standardUserDefaults] stringForKey:@"subscription_preference"]
                                   atLevel:[[NSUserDefaults standardUserDefaults] integerForKey:@"subscriptionqos_preference"]];
            while ([self.fifo count]) {
                /*
                 * if there are some queued send messages, send them
                 */
                NSDictionary *parameters = self.fifo[0];
                [self.fifo removeObjectAtIndex:0];
                [self sendData:parameters[@"DATA"] topic:parameters[@"TOPIC"] qos:[parameters[@"QOS"] intValue] retain:[parameters[@"RETAINFLAG"] boolValue]];
            }
            break;
        }
        case MQTTSessionEventConnectionClosed:
            self.lastClosed = [NSDate date];
            /* this informs the caller that the connection is closed 
             * specifically, the caller can end the background task now */
            self.state = state_closed;
            self.state = state_starting;
            break;
        case MQTTSessionEventProtocolError:
        case MQTTSessionEventConnectionRefused:
        case MQTTSessionEventConnectionError:
        {
#ifdef DEBUG
            NSLog(@"Connection setTimer %f", self.reconnectTime);
#endif
            self.reconnectTimer = [NSTimer timerWithTimeInterval:self.reconnectTime
                                                          target:self
                                                        selector:@selector(reconnect)
                                                        userInfo:Nil repeats:FALSE];
            NSRunLoop *runLoop = [NSRunLoop currentRunLoop];
            [runLoop addTimer:self.reconnectTimer
                      forMode:NSDefaultRunLoopMode];
            
            self.state = state_error;
            self.lastError = [NSDate date];
            self.lastErrorCode = error;
            break;
        }
        default:
            break;
    }
}

/*
 * Incoming Data Handler for subscriptions
 *
 * all incoming data is responded to by a publish of the current position
 *
 */

- (void)newMessage:(MQTTSession *)session data:(NSData *)data onTopic:(NSString *)topic
{
#ifdef DEBUG
    NSLog(@"Connection received %@ %@", topic, [Connection dataToString:data]);
#endif
    [self.delegate handleMessage:data onTopic:topic];
}

#pragma internal helpers

- (void)connectToInternal
{
    if (self.state == state_starting) {
        self.state = state_connecting;
        
        self.session = [[MQTTSession alloc] initWithClientId:[[NSUserDefaults standardUserDefaults] stringForKey:@"clientid_preference"]
                                                    userName:self.lastAuth ? self.lastUser : @""
                                                    password:self.lastAuth ? self.lastPass : @""
                                                   keepAlive:self.lastKeepalive
                                                cleanSession:self.lastClean
                                                   willTopic:self.lastWillTopic
                                                     willMsg:self.lastWill
                                                     willQoS:self.lastWillQos
                                              willRetainFlag:self.lastWillRetainFlag
                                                     runLoop:[NSRunLoop currentRunLoop]
                                                     forMode:NSDefaultRunLoopMode];
        [self.session setDelegate:self];
        [self.session connectToHost:self.lastHost
                               port:self.lastPort
                           usingSSL:self.lastTls];
    } else {
        NSLog(@"MQTTitude not starting, can't connect");
    }
}

- (NSString *)url
{
    return [NSString stringWithFormat:@"%@%@:%d",
            self.lastAuth ? [NSString stringWithFormat:@"%@@", self.lastUser] : @"",
            self.lastHost,
            self.lastPort
            ];
}

+ (NSString *)dataToString:(NSData *)data
{
    /* the following lines are necessary to convert data which is possibly not null-terminated into a string */
    NSString *message = [[NSString alloc] init];
    for (int i = 0; i < data.length; i++) {
        char c;
        [data getBytes:&c range:NSMakeRange(i, 1)];
        message = [message stringByAppendingFormat:@"%c", c];
    }
    return message;
}

- (void)setState:(NSInteger)state
{
    _state = state;
#ifdef DEBUG
    const NSDictionary *states = @{
                                   @(state_starting): @"starting",
                                   @(state_connecting): @"connecting",
                                   @(state_error): @"error",
                                   @(state_connected): @"connected",
                                   @(state_closing): @"closing",
                                   @(state_closed): @"closed"
                                   };
    
    NSLog(@"Connection state %@ (%d)", states[@(self.state)], self.state);
#endif
    [self.delegate showState:self.state];
}

- (NSArray *)fifo
{
    if (!_fifo)
        _fifo = [[NSMutableArray alloc] init];
    return _fifo;
}


- (void)reconnect
{
#ifdef DEBUG
    NSLog(@"Connection reconnect");
#endif
    
    self.reconnectTimer = nil;
    if (self.reconnectTime < RECONNECT_TIMER_MAX) {
        self.reconnectTime *= 2;
    }
    self.state = state_starting;
    
    [self connectToInternal];
}

- (void)connectToLast
{
#ifdef DEBUG
    NSLog(@"Connection connectToLast");
#endif
    
    self.reconnectTime = RECONNECT_TIMER;
    
    [self connectToInternal];
}



@end
