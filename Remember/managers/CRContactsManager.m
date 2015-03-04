//
//  CRContactsManager.m
//  
//
//  Created by Lee on 11/10/14.
//
//

#import "CRContactsManager.h"
#import "NSDate+Extend.h"
#import "RHAddressBook.h"
#import "RHPerson.h"
#import <AFNetworking/AFNetworking.h>

@interface CRContactsManager()
@property (nonatomic, strong) RHAddressBook *addressbook;
@end

@implementation CRContactsManager
@synthesize lastUpdated = _lastUpdated;
@synthesize lastChecked = _lastChecked;
@synthesize lastOpened = _lastOpened;
@synthesize lastOpenedOld = _lastOpenedOld;

+ (CRContactsManager *)sharedManager{
    static CRContactsManager *manager;
    if (!manager) {
        static dispatch_once_t onceToken;
        dispatch_once(&onceToken, ^{
            manager = [[CRContactsManager alloc] init];
        });
    }
    return manager;
}

- (CRContactsManager *)init{
    self = [super init];
    if (self) {
        // load addressbook
        _addressbook = [[RHAddressBook alloc] init];
        
        //check addressbook access
        //query current status, pre iOS6 always returns Authorized
        if ([RHAddressBook authorizationStatus] == RHAuthorizationStatusNotDetermined){
            
            //request authorization
            [_addressbook requestAuthorizationWithCompletion:^(bool granted, NSError *error) {
                [[NSNotificationCenter defaultCenter] postNotificationName:kAdressbookReady object:nil];
            }];
		}else if ([RHAddressBook authorizationStatus] == RHAuthorizationStatusAuthorized){
			[[NSNotificationCenter defaultCenter] postNotificationName:kAdressbookReady object:nil];
		}
			
        // start observing
        [[NSNotificationCenter defaultCenter]  addObserverForName:RHAddressBookExternalChangeNotification object:nil queue:nil usingBlock:^(NSNotification *note) {
			DDLogInfo(@"Observed changes to AddressBook");
            _allContacts = nil;
			//[self checkNewContactsAndNotifyWithCompletion:nil];
        }];
		
		//time stamp
		[[NSNotificationCenter defaultCenter] addObserverForName:UIApplicationDidEnterBackgroundNotification object:nil queue:nil usingBlock:^(NSNotification *note) {
			DDLogInfo(@"Observed app enter background");
			//update last opened
            self.lastOpened = [NSDate date];
		}];
        
        //print out all times
        DDLogInfo(@"Last checked: %@", self.lastChecked.string);
        DDLogInfo(@"Last updated: %@", self.lastUpdated.string);
        DDLogInfo(@"Last opened: %@", self.lastOpened.string);
        DDLogInfo(@"Last second opened: %@", self.lastOpenedOld.string);
    }
    
    return self;
}


- (NSArray *)allContacts{
    if (!_allContacts) {
        NSArray *peopleWithoutCreationDate = [[_addressbook people] filteredArrayUsingPredicate:[NSPredicate predicateWithFormat:@"created = nil"]];
        for (RHPerson  *person in peopleWithoutCreationDate) {
            NSParameterAssert(!person.created);
            NSDate *lastWeek = [[NSDate date] dateByAddingTimeInterval:-3600*24*30];
            [person setBasicValue:(__bridge CFTypeRef)lastWeek forPropertyID:kABPersonCreationDateProperty error:nil];
            DDLogVerbose(@"Set created for person %@", person.name);
        }
        _allContacts = [[_addressbook people] sortedArrayUsingDescriptors:@[[NSSortDescriptor sortDescriptorWithKey:@"created" ascending:NO]]];
    }
    return _allContacts;
}


//contacts added since last updates, used as default view
- (NSArray *)recentContacts{
    NSDate *lastOpenedOld = self.lastOpenedOld;
    NSArray *recents = [[_addressbook people] bk_select:^BOOL(RHPerson *person) {
        return [person.created timeIntervalSinceDate:lastOpenedOld] > 0;
    }];
    
    return [recents sortedArrayUsingDescriptors:@[[NSSortDescriptor sortDescriptorWithKey:@"created" ascending:NO]]];
}


#pragma mark - Check new
- (void)checkNewContactsAndNotifyWithCompletion:(void (^)(NSArray *newContacts))block{
    //check
	NSArray *newContacts = [self newContactsSinceLastCheck];
    //update time
    self.lastChecked = [NSDate date];
    
    
	if (newContacts.count) {
        DDLogInfo(@"Found %ld new contacts since last checked %@", (unsigned long)newContacts.count, _lastChecked.string);
        self.lastUpdated = [NSDate date];//doesn't matter
        //move the lastOpened old time to real last opened time, so the user will see newly updated contacts
        self.lastOpenedOld = self.lastOpened;
        [[NSUserDefaults standardUserDefaults] synchronize];
        
		//name
		NSArray *names = [newContacts valueForKey:@"name"];
		NSString *reminderStr;
		if (names.count > 1) {
			reminderStr = [NSString stringWithFormat:@"You recently met %@ and %ld other people. Add a quick note?", names.firstObject, names.count-1];
		} else {
			reminderStr = [NSString stringWithFormat:@"You recently met %@. Add a quick note?", names.firstObject];
		}
		
		//send notification
		UILocalNotification *note = [UILocalNotification new];
		note.alertBody = reminderStr;
		note.soundName = @"reminder.caf";
		note.category = kReminderCategory;
		note.fireDate = [NSDate date].nextNoon;//TODO: use created time

		[[UIApplication sharedApplication] scheduleLocalNotification:note];
        
        //schedule on server push
        [self sendNewContactsReminderPush:reminderStr];
        
        
	}
    
    if (block) {
        block(newContacts);
    }
}

- (void)sendNewContactsReminderPush:(NSString *)string{
    //schedule server push
    if (![PFInstallation currentInstallation].objectId) {
        return;
    }
    
    AFHTTPRequestOperationManager *manager = [AFHTTPRequestOperationManager manager];
    manager.requestSerializer = [AFJSONRequestSerializer serializer];
    [manager.requestSerializer setValue:kParseApplicationId forHTTPHeaderField:@"X-Parse-Application-Id"];
    [manager.requestSerializer setValue:kParseRestAPIId forHTTPHeaderField:@"X-Parse-REST-API-Key"];
    [manager.requestSerializer setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
    
    NSDate *nextNoon = [NSDate date].nextNoon;
#ifdef DEBUG
    nextNoon = [[NSDate date] dateByAddingTimeInterval:10];
#endif
    NSDictionary *dic = @{@"where":@{@"objectId":[PFInstallation currentInstallation].objectId},
                          @"push_time":[NSNumber numberWithDouble:[nextNoon timeIntervalSince1970]],
                          @"data":@{@"alert": string,
                                    @"content-available":@1,
                                    @"category": kReminderCategory,
                                    @"sound": @"reminder.caf",
                                    @"bedge": @"Incremental"},
                          };
    
    [manager POST:@"https://api.parse.com/1/push" parameters:dic
          success:^(AFHTTPRequestOperation *operation,id responseObject) {
              
              NSLog(@"SCHEDULED reminder PUSH success for time %@", nextNoon.string);
              
          }failure:^(AFHTTPRequestOperation *operation,NSError *error) {
              
              NSLog(@"Schedule Push Error: %@", error);
          }];
}

- (NSArray *)newContactsSinceLastCheck{
    NSDate *lastChecked = self.lastChecked;
    NSArray *newContacts = [[_addressbook people] bk_select:^BOOL(RHPerson *person) {
        return [person.created timeIntervalSinceDate:lastChecked] > 0;
    }];
    
    return newContacts;
}


#pragma mark - time stamp
- (NSDate *)lastChecked{
    _lastChecked = [[NSUserDefaults standardUserDefaults] objectForKey:kLastChecked];
    if (!_lastChecked) {
        DDLogInfo(@"first time check");
        self.lastChecked = [NSDate date];
    }
    return _lastChecked;
}

- (void)setLastChecked:(NSDate *)lastChecked{
    _lastChecked = lastChecked;
    [[NSUserDefaults standardUserDefaults] setObject:lastChecked forKey:kLastChecked];
}

- (NSDate *)lastUpdated{
    _lastUpdated = [[NSUserDefaults standardUserDefaults] objectForKey:kLastUpdated];
    if (!_lastUpdated) {
        DDLogInfo(@"first time update");
        self.lastUpdated = [NSDate date];
    }
    return _lastUpdated;
}

- (void)setLastUpdated:(NSDate *)lastUpdate{
    _lastUpdated = lastUpdate;
    [[NSUserDefaults standardUserDefaults] setObject:lastUpdate forKey:kLastUpdated];
}

- (NSDate *)lastOpened{
	_lastOpened = [[NSUserDefaults standardUserDefaults] objectForKey:kLastOpened];
	if (!_lastOpened) {
        self.lastOpened = [NSDate date];
	}
	return _lastOpened;
}

- (void)setLastOpened:(NSDate *)lastOpened{
	DDLogInfo(@"Last opened set to: %@", lastOpened.string);
    _lastOpened = lastOpened;
	[[NSUserDefaults standardUserDefaults] setObject:_lastOpened forKey:kLastOpened];
}

- (NSDate *)lastOpenedOld{
    _lastOpenedOld = [[NSUserDefaults standardUserDefaults] objectForKey:kLastOpenedOld];
    if (!_lastOpenedOld) {
        self.lastOpenedOld = [NSDate date];
    }
	return _lastOpenedOld;
}

- (void)setLastOpenedOld:(NSDate *)lastOpenedOld{
    _lastOpenedOld = lastOpenedOld;
    DDLogInfo(@"Last opened old set to: %@", lastOpenedOld.string);
	[[NSUserDefaults standardUserDefaults] setObject:_lastOpenedOld forKey:kLastOpenedOld];
}
@end
