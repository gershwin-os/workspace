/* ddbd.m
 *  
 * Copyright (C) 2004 Free Software Foundation, Inc.
 *
 * Author: Enrico Sersale <enrico@imago.ro>
 * Date: February 2004
 *
 * This file is part of the GNUstep GWorkspace application
 *
 * This program is free software; you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation; either version 2 of the License, or
 * (at your option) any later version.
 * 
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU General Public License for more details.
 * 
 * You should have received a copy of the GNU General Public License
 * along with this program; if not, write to the Free Software
 * Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston, MA 02111 USA.
 */

#include <AppKit/AppKit.h>
#include <DBKit/DBKBTreeNode.h>
#include <DBKit/DBKVarLenRecordsFile.h>
#include "ddbd.h"
#include "DDBPathsManager.h"
#include "DDBDirsManager.h"
#include "config.h"

#define GWDebugLog(format, args...) \
  do { if (GW_DEBUG_LOG) \
    NSLog(format , ## args); } while (0)
    
enum {   
  DDBdInsertTreeUpdate,
  DDBdRemoveTreeUpdate,
  DDBdFileOperationUpdate
};

static DDBPathsManager *pathsManager = nil; 
static NSRecursiveLock *pathslock = nil; 
static DDBDirsManager *dirsManager = nil; 
static NSRecursiveLock *dirslock = nil; 

static NSFileManager *fm = nil;


@implementation	DDBd

- (void)dealloc
{
  [[NSDistributedNotificationCenter defaultCenter] removeObserver: self];

  if (conn) {
    [nc removeObserver: self
		              name: NSConnectionDidDieNotification
		            object: conn];
    DESTROY (conn);
  }

  RELEASE (dbdir);
            
  [super dealloc];
}

- (id)init
{
  self = [super init];
  
  if (self) {   
    NSString *basepath;
    BOOL isdir;
    
    fm = [NSFileManager defaultManager];
    
    basepath = [NSSearchPathForDirectoriesInDomains(NSLibraryDirectory, NSUserDomainMask, YES) lastObject];
    ASSIGN (dbdir, [basepath stringByAppendingPathComponent: @"ddbd"]);

    if (([fm fileExistsAtPath: dbdir isDirectory: &isdir] &isdir) == NO) {
      if ([fm createDirectoryAtPath: dbdir attributes: nil] == NO) { 
        NSLog(@"unable to create: %@", dbdir);
        DESTROY (self);
        return self;
      }
    }

    nc = [NSNotificationCenter defaultCenter];
               
    conn = [NSConnection defaultConnection];
    [conn setRootObject: self];
    [conn setDelegate: self];

    if ([conn registerName: @"ddbd"] == NO) {
	    NSLog(@"unable to register with name server - quiting.");
	    DESTROY (self);
	    return self;
	  }
          
    [nc addObserver: self
           selector: @selector(connectionBecameInvalid:)
	             name: NSConnectionDidDieNotification
	           object: conn];

    [nc addObserver: self
       selector: @selector(threadWillExit:)
           name: NSThreadWillExitNotification
         object: nil];    
    
    [[NSDistributedNotificationCenter defaultCenter] addObserver: self 
                				  selector: @selector(fileSystemDidChange:) 
                					    name: @"GWFileSystemDidChangeNotification"
                					  object: nil];

    pathsManager = [[DDBPathsManager alloc] initWithBasePath: dbdir];
    pathslock = [NSRecursiveLock new];
    dirsManager = [[DDBDirsManager alloc] initWithBasePath: dbdir];
    dirslock = [NSRecursiveLock new];
        
    NSLog(@"ddbd started");    
  }
  
  return self;    
}

- (BOOL)dbactive
{
  return YES;
}

- (BOOL)insertPath:(NSString *)path
{
  NSDictionary *attributes = [fm fileAttributesAtPath: path traverseLink: NO];

  if (attributes) {
    [pathslock lock];
    [pathsManager addPath: path];
    [pathslock unlock];
    
    if ([attributes fileType] == NSFileTypeDirectory) {
      [dirslock lock];
      [dirsManager addDirectory: path];
      [dirslock unlock];
    }
  }

  return YES; 
}

- (BOOL)removePath:(NSString *)path
{
  [pathslock lock];
  [pathsManager removePath: path];
  [pathslock unlock];
  
  [dirslock lock];
  [dirsManager removeDirectory: path];
  [dirslock unlock];
  
  return YES; 
}

- (void)insertDirectoryTreesFromPaths:(NSData *)info
{
  NSArray *paths = [NSUnarchiver unarchiveObjectWithData: info];
  NSMutableDictionary *updaterInfo = [NSMutableDictionary dictionary];
  NSDictionary *dict = [NSDictionary dictionaryWithObject: paths 
                                                   forKey: @"paths"];
    
  [updaterInfo setObject: [NSNumber numberWithInt: DDBdInsertTreeUpdate] 
                  forKey: @"type"];
  [updaterInfo setObject: dict forKey: @"taskdict"];

  NS_DURING
    {
      [NSThread detachNewThreadSelector: @selector(updaterForTask:)
		                           toTarget: [DBUpdater class]
		                         withObject: updaterInfo];
    }
  NS_HANDLER
    {
      NSLog(@"A fatal error occured while detaching the thread!");
    }
  NS_ENDHANDLER
}

- (void)removeTreesFromPaths:(NSData *)info
{
  NSArray *paths = [NSUnarchiver unarchiveObjectWithData: info];
  NSMutableDictionary *updaterInfo = [NSMutableDictionary dictionary];
  NSDictionary *dict = [NSDictionary dictionaryWithObject: paths 
                                                   forKey: @"paths"];

  [updaterInfo setObject: [NSNumber numberWithInt: DDBdRemoveTreeUpdate] 
                  forKey: @"type"];
  [updaterInfo setObject: dict forKey: @"taskdict"];

  NS_DURING
    {
      [NSThread detachNewThreadSelector: @selector(updaterForTask:)
		                           toTarget: [DBUpdater class]
		                         withObject: updaterInfo];
    }
  NS_HANDLER
    {
      NSLog(@"A fatal error occured while detaching the thread!");
    }
  NS_ENDHANDLER
}

- (NSData *)directoryTreeFromPath:(NSString *)apath
{  
  CREATE_AUTORELEASE_POOL(pool);
  NSArray *directories;  
  NSData *data = nil;
  
  [dirslock lock];
  directories = [dirsManager dirsFromPath: apath];
  [dirslock unlock];
    
  if ([directories count]) { 
    data = [NSArchiver archivedDataWithRootObject: directories]; 
  } 

  TEST_RETAIN (data);
  RELEASE (pool);
  
  return TEST_AUTORELEASE (data);
}

- (NSString *)annotationsForPath:(NSString *)path
{
  NSString *annotations;
  
  [pathslock lock];
  annotations = [pathsManager metadataOfType: @"MDAnnotations" forPath: path];
  [pathslock unlock];
  
  return annotations;
}

- (oneway void)setAnnotations:(NSString *)annotations
                      forPath:(NSString *)path
{
  [pathslock lock];
  [pathsManager setMetadata: annotations 
                     ofType: @"MDAnnotations" 
                    forPath: path];
  [pathslock unlock];                    
}

- (NSTimeInterval)timestampOfPath:(NSString *)path
{
  NSTimeInterval interval;

  [pathslock lock];
  interval = [pathsManager timestampOfPath: path];
  [pathslock unlock];
  
  return interval;
}

- (oneway void)synchronize
{
  [pathslock lock];
  [pathsManager synchronize];
  [pathslock unlock];
  
  [dirslock lock];
  [dirsManager synchronize];
  [dirslock unlock];
}

- (void)connectionBecameInvalid:(NSNotification *)notification
{
  id connection = [notification object];

  [nc removeObserver: self
	              name: NSConnectionDidDieNotification
	            object: connection];

  if (connection == conn) {
    NSLog(@"argh - ddbd root connection has been destroyed.");
    exit(EXIT_FAILURE);
  } 
}

- (BOOL)connection:(NSConnection *)ancestor
            shouldMakeNewConnection:(NSConnection *)newConn;
{
  [nc addObserver: self
         selector: @selector(connectionBecameInvalid:)
	           name: NSConnectionDidDieNotification
	         object: newConn];
           
  [newConn setDelegate: self];
  
  return YES;
}

- (void)fileSystemDidChange:(NSNotification *)notif
{
  NSDictionary *info = [notif userInfo];
  NSMutableDictionary *updaterInfo = [NSMutableDictionary dictionary];
    
  [updaterInfo setObject: [NSNumber numberWithInt: DDBdFileOperationUpdate] 
                  forKey: @"type"];
  [updaterInfo setObject: info forKey: @"taskdict"];

  NS_DURING
    {
      [NSThread detachNewThreadSelector: @selector(updaterForTask:)
		                           toTarget: [DBUpdater class]
		                         withObject: updaterInfo];
    }
  NS_HANDLER
    {
      NSLog(@"A fatal error occured while detaching the thread!");
    }
  NS_ENDHANDLER
}

- (void)threadWillExit:(NSNotification *)notification
{
  NSLog(@"db update done");
}

@end


@implementation	DBUpdater

- (void)dealloc
{
  RELEASE (updinfo);
	[super dealloc];
}

+ (void)updaterForTask:(NSDictionary *)info
{
  CREATE_AUTORELEASE_POOL(arp);
  DBUpdater *updater = [[self alloc] init];
  
  [updater setUpdaterTask: info];
  RELEASE (updater);
                              
  [[NSRunLoop currentRunLoop] run];
  RELEASE (arp);
}

- (void)setUpdaterTask:(NSDictionary *)info
{
  NSDictionary *dict = [info objectForKey: @"taskdict"];
  int type = [[info objectForKey: @"type"] intValue];
  
  ASSIGN (updinfo, dict);
  
  RETAIN (self);
    
  NSLog(@"starting db update");

  switch(type) {
    case DDBdInsertTreeUpdate:
      [self insertTrees];
      break;

    case DDBdRemoveTreeUpdate:
      [self removeTrees];
      break;

    case DDBdFileOperationUpdate:
      [self fileSystemDidChange];
      break;

    default:
      [self done];
      break;
  }
}

- (void)done
{
  RELEASE (self);
  [NSThread exit];
}

- (void)insertTrees
{
  NSArray *paths = [updinfo objectForKey: @"paths"];
  
  [dirslock lock];
  [dirsManager insertDirsFromPaths: paths];
  [dirslock unlock];

  [self done];
}

- (void)removeTrees
{
  NSArray *paths = [updinfo objectForKey: @"paths"];
  
  [dirslock lock];
  [dirsManager removeDirsFromPaths: paths];
  [dirslock unlock];

  [self done];
}

- (void)fileSystemDidChange
{
  NSString *operation = [updinfo objectForKey: @"operation"];

  if ([operation isEqual: @"NSWorkspaceMoveOperation"] 
                || [operation isEqual: @"NSWorkspaceCopyOperation"]
                || [operation isEqual: @"NSWorkspaceDuplicateOperation"]
                || [operation isEqual: @"GWorkspaceRenameOperation"]) {
    CREATE_AUTORELEASE_POOL(arp);
    NSString *source = [updinfo objectForKey: @"source"];
    NSString *destination = [updinfo objectForKey: @"destination"];
    NSArray *files = [updinfo objectForKey: @"files"];
    NSArray *origfiles = [updinfo objectForKey: @"origfiles"];
    NSMutableArray *srcpaths = [NSMutableArray array];
    NSMutableArray *dstpaths = [NSMutableArray array];
    int i;
    
    if ([operation isEqual: @"GWorkspaceRenameOperation"]) {
      srcpaths = [NSArray arrayWithObject: source];
      dstpaths = [NSArray arrayWithObject: destination];
    } else {
      if ([operation isEqual: @"NSWorkspaceDuplicateOperation"]) { 
        for (i = 0; i < [files count]; i++) {
          NSString *fname = [origfiles objectAtIndex: i];
          [srcpaths addObject: [source stringByAppendingPathComponent: fname]];
          fname = [files objectAtIndex: i];
          [dstpaths addObject: [destination stringByAppendingPathComponent: fname]];
        }
      } else {  
        for (i = 0; i < [files count]; i++) {
          NSString *fname = [files objectAtIndex: i];
          [srcpaths addObject: [source stringByAppendingPathComponent: fname]];
          [dstpaths addObject: [destination stringByAppendingPathComponent: fname]];
        }
      }
    }
    
    [pathslock lock];
    [pathsManager duplicateDataOfPaths: srcpaths forPaths: dstpaths];
    [pathslock unlock];
    
    RELEASE (arp);
  }
  
  [self done];
}

@end


BOOL subpath(NSString *p1, NSString *p2)
{
  int l1 = [p1 length];
  int l2 = [p2 length];  

  if ((l1 > l2) || ([p1 isEqualToString: p2])) {
    return NO;
  } else if ([[p2 substringToIndex: l1] isEqualToString: p1]) {
    if ([[p2 pathComponents] containsObject: [p1 lastPathComponent]]) {
      return YES;
    }
  }

  return NO;
}

static NSString *fixpath(NSString *s, const char *c)
{
  static NSFileManager *mgr = nil;
  const char *ptr = c;
  unsigned len;

  if (mgr == nil) {
    mgr = [NSFileManager defaultManager];
    RETAIN (mgr);
  }
  
  if (ptr == 0) {
    if (s == nil) {
	    return nil;
	  }
    ptr = [s cString];
  }
  
  len = strlen(ptr);

  return [mgr stringWithFileSystemRepresentation: ptr length: len]; 
}

static NSString *path_sep(void)
{
  static NSString *separator = nil;

  if (separator == nil) {
    separator = fixpath(@"/", 0);
    RETAIN (separator);
  }

  return separator;
}

NSString *pathsep(void)
{
  return path_sep();
}

NSString *removePrefix(NSString *path, NSString *prefix)
{
  if ([path hasPrefix: prefix]) {
	  return [path substringFromIndex: [path rangeOfString: prefix].length + 1];
  }

  return path;  	
}


int main(int argc, char** argv)
{
  CREATE_AUTORELEASE_POOL(pool);
  NSProcessInfo *info = [NSProcessInfo processInfo];
  NSMutableArray *args = AUTORELEASE ([[info arguments] mutableCopy]);
  static BOOL	is_daemon = NO;
  BOOL subtask = YES;

  if ([[info arguments] containsObject: @"--daemon"]) {
    subtask = NO;
    is_daemon = YES;
  }

  if (subtask) {
    NSTask *task = [NSTask new];
    
    NS_DURING
	    {
	      [args removeObjectAtIndex: 0];
	      [args addObject: @"--daemon"];
	      [task setLaunchPath: [[NSBundle mainBundle] executablePath]];
	      [task setArguments: args];
	      [task setEnvironment: [info environment]];
	      [task launch];
	      DESTROY (task);
	    }
    NS_HANDLER
	    {
	      fprintf (stderr, "unable to launch the ddbd task. exiting.\n");
	      DESTROY (task);
	    }
    NS_ENDHANDLER
      
    exit(EXIT_FAILURE);
  }
  
  RELEASE(pool);

  {
    CREATE_AUTORELEASE_POOL (pool);
	  DDBd *ddbd = [[DDBd alloc] init];
    RELEASE (pool);

    if (ddbd != nil) {
	    CREATE_AUTORELEASE_POOL (pool);
      [[NSRunLoop currentRunLoop] run];
  	  RELEASE (pool);
    }
  }
    
  exit(EXIT_SUCCESS);
}
