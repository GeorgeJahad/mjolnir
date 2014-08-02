#import "PKExtManager.h"
#import "PKExtension.h"

NSString* PKExtensionsUpdatedNotification = @"PKExtensionsUpdatedNotification";

static NSString* PKMasterShaURL = @"https://api.github.com/repos/penknife-io/ext/git/refs/heads/master";
static NSString* PKTreeListURL  = @"https://api.github.com/repos/penknife-io/ext/git/trees/master";
static NSString* PKRawFilePathURLTemplate = @"https://raw.githubusercontent.com/penknife-io/ext/%@/%@";

@implementation PKExtManager

+ (PKExtManager*) sharedExtManager {
    static PKExtManager* sharedExtManager;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        sharedExtManager = [[PKExtManager alloc] init];
    });
    return sharedExtManager;
}

- (void) getURL:(NSString*)urlString handleJSON:(void(^)(id json))handler {
    // come on apple srsly
    NSURL* url = [NSURL URLWithString:urlString];
    NSURLRequest* req = [NSURLRequest requestWithURL:url cachePolicy:NSURLRequestReloadIgnoringLocalCacheData timeoutInterval:5.0];
    [NSURLConnection sendAsynchronousRequest:req
                                       queue:[NSOperationQueue mainQueue]
                           completionHandler:^(NSURLResponse *response, NSData *data, NSError *connectionError) {
                               if (data) {
                                   NSError* __autoreleasing jsonError;
                                   id obj = [NSJSONSerialization JSONObjectWithData:data options:0 error:&jsonError];
                                   if (obj)
                                       handler(obj);
                                   else
                                       NSLog(@"json error: %@", jsonError);
                               }
                               else {
                                   NSLog(@"connection error: %@", connectionError);
                               }
                           }];
}

- (void) update {
    if (self.updating) return;
    self.updating = YES;
    
    [self getURL:PKMasterShaURL handleJSON:^(NSDictionary* json) {
        NSString* newsha = [[json objectForKey:@"object"] objectForKey:@"sha"];
        
        // we need this to get the sha for the rawgithubcontent url (can't just use 'master' in case github's cache fails us)
        // we can also use it to quickly know if we need to fetch the full file dir.
        
        if ([newsha isEqualToString: self.cache.sha]) {
            NSLog(@"no update found.");
            self.updating = NO;
            return;
        }
        
        NSLog(@"update found!");
        
        self.cache.sha = newsha;
        
        [self getURL:PKTreeListURL handleJSON:^(NSDictionary* json) {
            NSMutableArray* newlist = [NSMutableArray array];
            for (NSDictionary* file in [json objectForKey:@"tree"]) {
                NSString* path = [file objectForKey:@"path"];
                if ([path hasSuffix:@".json"])
                    [newlist addObject:@{@"path": path, @"sha": [file objectForKey:@"sha"]}];
            }
            [self reflectAvailableExts:newlist];
        }];
    }];
}

- (void) storeJSON:(NSDictionary*)json inExt:(NSString*)namePath sha:(NSString*)sha {
    PKExtension* ext = [[PKExtension alloc] init];
    [self.cache.extensions addObject:ext];
    
    ext.sha = sha;
    ext.name = [namePath stringByReplacingOccurrencesOfString:@".json" withString:@""];
    ext.version = [json objectForKey:@"version"];
    ext.license = [json objectForKey:@"license"];
    ext.tarfile = [json objectForKey:@"tarfile"];
    ext.website = [json objectForKey:@"website"];
    ext.author = [json objectForKey:@"author"];
}

- (void) doneUpdating {
    [self.cache.extensions sortUsingComparator:^NSComparisonResult(PKExtension* a, PKExtension* b) {
        return [a.name compare: b.name];
    }];
    
    NSLog(@"done updating.");
    self.updating = NO;
    [[NSNotificationCenter defaultCenter] postNotificationName:PKExtensionsUpdatedNotification object:nil];
    [self.cache save];
}

- (void) reflectAvailableExts:(NSArray*)latestexts {
    // 1. look for all old shas missing from the new batch and delete their represented local files
    // 2. look for all new shas missing from old batch and download their files locally
    
    NSArray* oldshas = [self.cache.extensions valueForKeyPath:@"sha"];
    NSArray* latestshas = [latestexts valueForKeyPath:@"sha"];
    
    NSArray* removals = [self.cache.extensions filteredArrayUsingPredicate:[NSPredicate predicateWithFormat:@"NOT self.sha IN %@", latestshas]];
    NSArray* additions = [latestexts filteredArrayUsingPredicate:[NSPredicate predicateWithFormat:@"NOT sha IN %@", oldshas]];
    
    for (PKExtension* oldext in removals)
        [self.cache.extensions removeObject:oldext];
    
    __block NSUInteger waitingfor = [additions count];
    
    if (waitingfor == 0) {
        [self doneUpdating];
    }
    
    for (NSDictionary* ext in additions) {
        NSString* extNamePath = [ext objectForKey: @"path"];
        NSString* url = [NSString stringWithFormat:PKRawFilePathURLTemplate, self.cache.sha, extNamePath];
        NSLog(@"downloading: %@", url);
        
        [self getURL:url handleJSON:^(NSDictionary* json) {
            [self storeJSON:json inExt:extNamePath sha:[ext objectForKey: @"sha"]];
            
            if (--waitingfor == 0) {
                [self doneUpdating];
            }
        }];
    }
}

- (void) setup {
    self.cache = [PKExtensionCache cache];
    [[NSNotificationCenter defaultCenter] postNotificationName:PKExtensionsUpdatedNotification object:nil];
    [self update];
}

@end