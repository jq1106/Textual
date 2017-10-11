/* ********************************************************************* 
                  _____         _               _
                 |_   _|____  _| |_ _   _  __ _| |
                   | |/ _ \ \/ / __| | | |/ _` | |
                   | |  __/>  <| |_| |_| | (_| | |
                   |_|\___/_/\_\\__|\__,_|\__,_|_|

 Copyright (c) 2008 - 2010 Satoshi Nakagawa <psychs AT limechat DOT net>
 Copyright (c) 2010 - 2015 Codeux Software, LLC & respective contributors.
        Please see Acknowledgements.pdf for additional information.

 Redistribution and use in source and binary forms, with or without
 modification, are permitted provided that the following conditions
 are met:

    * Redistributions of source code must retain the above copyright
      notice, this list of conditions and the following disclaimer.
    * Redistributions in binary form must reproduce the above copyright
      notice, this list of conditions and the following disclaimer in the
      documentation and/or other materials provided with the distribution.
    * Neither the name of Textual and/or "Codeux Software, LLC", nor the 
      names of its contributors may be used to endorse or promote products 
      derived from this software without specific prior written permission.

 THIS SOFTWARE IS PROVIDED BY THE AUTHOR AND CONTRIBUTORS ``AS IS'' AND
 ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
 IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE
 ARE DISCLAIMED. IN NO EVENT SHALL THE AUTHOR OR CONTRIBUTORS BE LIABLE
 FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL
 DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS
 OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION)
 HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT
 LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY
 OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF
 SUCH DAMAGE.

 *********************************************************************** */

NS_ASSUME_NONNULL_BEGIN

#define _enqueueBlock(operationBlock)			\
	[self.printingQueue enqueueMessageBlock:(operationBlock) for:self isStandalone:NO];

#define _enqueueBlockStandalone(operationBlock)			\
	[self.printingQueue enqueueMessageBlock:(operationBlock) for:self isStandalone:YES];

@interface TVCLogControllerPrintOperationContext ()
@property (nonatomic, weak, readwrite) IRCClient *client;
@property (nonatomic, weak, readwrite) IRCChannel *channel;
@property (nonatomic, assign, readwrite, getter=isHighlight) BOOL highlight;
@property (nonatomic, copy, readwrite) TVCLogLine *logLine;
@property (nonatomic, copy, readwrite) NSString *lineNumber;
@end

@interface TVCLogController ()
@property (nonatomic, assign, readwrite, getter=viewIsLoaded) BOOL loaded;
@property (nonatomic, assign) BOOL terminating;
@property (nonatomic, assign) BOOL historyLoadedForFirstTime;
@property (nonatomic, assign) BOOL reloadingHistory;
@property (nonatomic, assign) BOOL reloadingTheme;
@property (nonatomic, assign) BOOL historyLoaded;
@property (nonatomic, assign) NSInteger activeLineCount;
@property (nonatomic, copy, nullable) NSString *lastVisitedHighlight;
@property (nonatomic, copy, nullable, readwrite) NSString *newestLineNumberFromPreviousSession;
@property (nonatomic, copy, nullable, readwrite) NSString *oldestLineNumber;
@property (nonatomic, copy, nullable, readwrite) NSString *newestLineNumber;
@property (nonatomic, strong) NSMutableArray<NSString *> *highlightedLineNumbers;
@property (nonatomic, strong) NSCache *jumpToLineCallbacks;
@property (nonatomic, strong, readwrite) TVCLogView *backingView;
@property (weak, readonly) IRCTreeItem *associatedItem;
@property (nonatomic, weak, readwrite) IRCClient *associatedClient;
@property (nonatomic, weak, readwrite) IRCChannel *associatedChannel;
@property (nonatomic, weak, readwrite) TVCMainWindow *attachedWindow;
@property (nonatomic, assign) NSTimeInterval viewLoadedTimestamp;
@property (readonly) TVCLogControllerPrintingOperationQueue *printingQueue;
@property (readonly, copy) NSURL *baseURL;
@end

NSString * const TVCLogControllerViewFinishedLoadingNotification = @"TVCLogControllerViewFinishedLoadingNotification";

@implementation TVCLogController

#pragma mark -
#pragma mark Initialization

ClassWithDesignatedInitializerInitMethod

- (instancetype)initWithClient:(IRCClient *)client inWindow:(TVCMainWindow *)window
{
	NSParameterAssert(client != nil);
	NSParameterAssert(window != nil);

	if ((self = [super init])) {
		self.associatedClient = client;

		self.attachedWindow = window;

		[self prepareInitialState];

		[self setUp];

		return self;
	}

	return nil;
}

- (instancetype)initWithChannel:(IRCChannel *)channel inWindow:(TVCMainWindow *)window
{
	NSParameterAssert(channel != nil);
	NSParameterAssert(window != nil);

	if ((self = [super init])) {
		self.associatedClient = channel.associatedClient;
		self.associatedChannel = channel;

		self.attachedWindow = window;

		[self prepareInitialState];

		[self setUp];

		return self;
	}

	return nil;
}

- (void)prepareInitialState
{
#if TEXTUAL_BUILT_WITH_ADVANCED_ENCRYPTION == 1
	self.encrypted = self.associatedChannel.encryptionStateIsEncrypted;
#endif

	self.highlightedLineNumbers	= [NSMutableArray new];

	self.jumpToLineCallbacks = [NSCache new];
}

- (void)prepareForTermination:(BOOL)isTerminatingApplication
{
	self.terminating = YES;

	self.loaded = NO;

	[self.backingView stopLoading]; // allow view to teardown
	self.backingView = nil;

	[self.printingQueue cancelOperationsForViewController:self];

	if (isTerminatingApplication) {
		[self closeHistoricLog];
	} else {
		[self historicLogForgetChannel];
	}
}

- (void)prepareForApplicationTermination
{
	[self prepareForTermination:YES];
}

- (void)prepareForPermanentDestruction
{
	[self prepareForTermination:NO];
}

- (void)dealloc
{
	[self cancelPerformRequests];
}

#pragma mark -
#pragma mark Create View

- (void)setUp
{
	[self buildBackingView];

	[self loadInitialDocument];
}

- (void)buildBackingView
{
	self.backingView = [[TVCLogView alloc] initWithViewController:self];
}

- (void)rebuildBackingView
{
	[self buildBackingView];

	if (self.visible) {
		[self.attachedWindow updateChannelViewBoxContentViewSelection];
	}
}

- (void)loadInitialDocument
{
	[self loadAlternateHTML:[self initialDocument]];
}

- (void)loadAlternateHTML:(NSString *)newHTML
{
	NSParameterAssert(newHTML != nil);

	[self.backingView stopLoading];

	[self.backingView loadHTMLString:newHTML baseURL:self.baseURL];
}

#pragma mark -
#pragma mark Manage Historic Log

- (void)historicLogForgetChannel
{
	/* Delete any trace of the channel, including context */
	[TVCLogControllerHistoricLogSharedInstance() forgetItem:self.associatedItem];
}
	
- (void)historicLogResetChannel
{
	/* Delete log for channel but keep context */
	[TVCLogControllerHistoricLogSharedInstance() resetDataForItem:self.associatedItem];
}

- (void)closeHistoricLog
{
	/* The historic log file is always open regardless of whether the user asked
	 Textual to remember the history between restarts. It is always open because
	 the reloading of a theme uses it to fill in the backlog after a reload.
	 -closeHistoricLog is the point where we decide to actually save the file
	 or erase it. If the user has Textual configured to remember between restarts,
	 then we call a save before terminating. Or, we just erase the file from the
	 path that it is written to entirely. */

	if (
		/* 1 */ [TPCPreferences reloadScrollbackOnLaunch] == NO ||
		/* 2 */  self.associatedChannel.isUtility ||
		/* 3 */ (self.associatedChannel.isPrivateMessage &&
				 [TPCPreferences rememberServerListQueryStates] == NO) ||
		/* 4 */ self.encrypted)
	{
		[self historicLogResetChannel];
	}
}

#pragma mark -
#pragma mark Properties

- (nullable IRCTreeItem *)associatedItem
{
	if (self.associatedChannel) {
		return self.associatedChannel;
	} else {
		return self.associatedClient;
	}
}

- (NSString *)uniqueIdentifier
{
	return self.associatedItem.uniqueIdentifier;
}

- (NSURL *)baseURL
{
	if (themeController().usesTemporaryPath) {
		NSString *temporaryPath = themeController().temporaryPath;

		return [NSURL fileURLWithPath:temporaryPath isDirectory:YES];
	}

	return themeController().baseURL;
}

- (TVCLogControllerPrintingOperationQueue *)printingQueue
{
    return [TXSharedApplication sharedPrintingQueue];
}

- (BOOL)inlineMediaEnabledForView
{
	if (self.associatedChannel == nil) {
		return NO;
	}

	/* If global showInlineImages is YES, then the value of ignoreInlineImages is designed to
	 be as it is named. Disable them for specific channels. However if showInlineImages is NO
	 on a global scale, then ignoreInlineImages actually enables them for specific channels. */
	return (([TPCPreferences showInlineImages]			&& self.associatedChannel.config.ignoreInlineMedia == NO) ||
			([TPCPreferences showInlineImages] == NO	&& self.associatedChannel.config.ignoreInlineMedia));
}

- (BOOL)viewIsSelected
{
	return (self.attachedWindow.selectedViewController == self);
}

- (BOOL)viewIsVisible
{
	if (self.associatedChannel) {
		return [self.attachedWindow isItemVisible:self.associatedChannel];
	} else {
		return [self.attachedWindow isItemVisible:self.associatedClient];
	}
}

#pragma mark -
#pragma mark Document Append & JavaScript Controller

- (void)evaluateFunction:(NSString *)function withArguments:(nullable NSArray *)arguments
{
	[self evaluateFunction:function withArguments:arguments onQueue:YES];
}

- (void)evaluateFunction:(NSString *)function withArguments:(nullable NSArray *)arguments onQueue:(BOOL)onQueue
{
	NSParameterAssert(function != nil);

	if (self.terminating) {
		return;
	}

	if (onQueue) {
		TVCLogControllerPrintingBlock scriptBlock = ^(id operation) {
			[self _evaluateFunction:function withArguments:arguments];
		};

		_enqueueBlock(scriptBlock)
	} else {
		[self _evaluateFunction:function withArguments:arguments];
	}
}

- (void)_evaluateFunction:(NSString *)function withArguments:(nullable NSArray *)arguments
{
	NSParameterAssert(function != nil);

	if (self.loaded == NO || self.terminating) {
		return;
	}

	[self.backingView evaluateFunction:function withArguments:arguments];
}

- (void)appendToDocumentBody:(NSString *)html withLineNumbers:(NSArray<NSString *> *)lineNumbers
{
	NSParameterAssert(html != nil);

	[self _evaluateFunction:@"MessageBuffer.bufferElementAppend" withArguments:@[html, lineNumbers]];
}

#pragma mark -
#pragma mark Channel Topic Bar

- (void)setInitialTopic
{
	NSString *topic = self.associatedChannel.topic;

	[self setTopic:topic];
}

- (void)setTopic:(nullable NSString *)topic
{
	if (self.terminating) {
		return;
	}

	TVCLogControllerPrintingBlock operationBlock = ^(id operation) {
		NSString *topicString = nil;

		if (topic == nil || topic.length == 0) {
			topicString = TXTLS(@"IRC[1038]");
		} else {
			topicString = topic;
		}

		NSString *topicTemplate = [TVCLogRenderer renderBody:topicString
										   forViewController:self
											  withAttributes:@{
													TVCLogRendererConfigurationRenderLinksAttribute : @YES,
													TVCLogRendererConfigurationLineTypeAttribute : @(TVCLogLineTopicType)
															}
												  resultInfo:NULL];

		[self _evaluateFunction:@"Textual.setTopicBarValue" withArguments:@[topicString, topicTemplate]];

		[self.backingView redrawView];
	};

	_enqueueBlockStandalone(operationBlock)
}

#pragma mark -
#pragma mark Move to Bottom/Top

- (void)moveToTop
{
	[self _evaluateFunction:@"Textual.scrollToTopOfView" withArguments:@[@(YES)]];
}

- (void)moveToBottom
{
	[self _evaluateFunction:@"Textual.scrollToBottomOfView" withArguments:@[@(YES)]];
}

#pragma mark -
#pragma mark Add/Remove History Mark

- (void)mark
{
	TVCLogControllerPrintingBlock operationBlock = ^(id operation) {
		NSString *markTemplate = [TVCLogRenderer renderTemplateNamed:@"historyIndicator"];

		[self _evaluateFunction:@"_Textual.historyIndicatorAdd" withArguments:@[markTemplate]];
	};

	_enqueueBlock(operationBlock);
}

- (void)unmark
{
	[self _evaluateFunction:@"_Textual.historyIndicatorRemove" withArguments:nil];
}

- (void)goToMark
{
	[self _evaluateFunction:@"Textual.scrollToHistoryIndicator" withArguments:nil];
}

#pragma mark -
#pragma mark Reload Scrollback

- (void)appendHistoricMessageFragment:(NSString *)html withLineNumbers:(NSArray<NSString *> *)lineNumbers isReload:(BOOL)isReload
{
	NSParameterAssert(html != nil);

	[self _evaluateFunction:@"_Textual.documentBodyAppendHistoric" withArguments:@[html, lineNumbers, @(isReload)]];
}

/* reloadOldLines: is supposed to be called from inside a queue. */
- (void)reloadOldLines:(NSArray<TVCLogLine *> *)oldLines isReload:(BOOL)isReload
{
	NSParameterAssert(oldLines != nil);

	NSMutableArray<NSString *> *lineNumbers = [NSMutableArray array];

	NSMutableString *patchedAppend = [NSMutableString string];

	NSMutableArray<THOPluginDidPostNewMessageConcreteObject *> *pluginObjects = nil;

	for (TVCLogLine *logLine in oldLines) {
		/* Render result info HTML */
		NSDictionary<NSString *, id> *resultInfo = nil;

		NSString *html = [self renderLogLine:logLine resultInfo:&resultInfo];

		if (html == nil) {
			LogToConsoleError("Failed to render log line %{public}@", logLine.description);

			continue;
		}

		[patchedAppend appendString:html];

		/* Record information about rendering */
		NSString *lineNumber = logLine.uniqueIdentifier;

		[lineNumbers addObject:lineNumber];

		/* Add "Current Session" message */
		if ([lineNumber isEqualToString:self.newestLineNumberFromPreviousSession]) {
			NSString *html = [self messageBufferSessionIndicatorWithMessage:TXTLS(@"IRC[1127]")];

			[patchedAppend appendString:html];
		}

		/* Add reference to plugin concrete object */
		THOPluginDidPostNewMessageConcreteObject *pluginObject = resultInfo[@"pluginConcreteObject"];

		if (pluginObject) {
			if (pluginObjects == nil) {
				pluginObjects = [NSMutableArray array];
			}

			[pluginObjects addObject:pluginObject];
		}

		/* Record highlights */
		BOOL highlighted = [resultInfo boolForKey:TVCLogRendererResultsKeywordMatchFoundAttribute];

		if (highlighted) {
			@synchronized(self.highlightedLineNumbers) {
				[self.highlightedLineNumbers addObject:lineNumber];
			}
		}
	}

	/* Render the result in WebKit */
	[self appendHistoricMessageFragment:patchedAppend withLineNumbers:lineNumbers isReload:isReload];

	/* Inform plugins of new content */
	for (THOPluginDidPostNewMessageConcreteObject *pluginObject in pluginObjects) {
		pluginObject.isProcessedInBulk = YES;

		[THOPluginDispatcher enqueueDidPostNewMessage:pluginObject];
	}
}

- (void)maybeReloadHistory
{
	if (self.loaded == NO) {
		return;
	}

	if (self.historyLoaded) {
		return;
	}

	[self reloadHistory];
}

- (void)reloadHistory
{
	if (self.terminating) {
		return;
	}

	BOOL firstTimeLoadingHistory = (self.historyLoadedForFirstTime == NO);

	if (
		/* 1 */ self.encrypted ||
		/* 2 */ (firstTimeLoadingHistory &&
				 [TPCPreferences reloadScrollbackOnLaunch] == NO) ||
		/* 3 */  self.associatedChannel.isUtility ||
		/* 4 */ (firstTimeLoadingHistory &&
				 self.associatedChannel.isPrivateMessage &&
				 [TPCPreferences rememberServerListQueryStates] == NO))
	{
		self.historyLoadedForFirstTime = YES;

		self.historyLoaded = YES;

		[self notifyViewFinishedLoadingHistory];

		return;
	} else {
		BOOL lazyLoadHistory = [RZUserDefaults() boolForKey:@"Optimizations -> Load History Lazily"];

		if (lazyLoadHistory && self.visible == NO) {
			return;
		}
	}

	self.reloadingHistory = YES;

	void (^reloadBlock)(NSArray *) = ^(NSArray<TVCLogLine *> *objects) {
		NSString *newestLineNumber = objects.lastObject.uniqueIdentifier;

		if (firstTimeLoadingHistory) {
			self.newestLineNumberFromPreviousSession = newestLineNumber;
		}

		[self reloadOldLines:objects isReload:(firstTimeLoadingHistory == NO)];

		self.reloadingHistory = NO;

		self.historyLoaded = YES;
		self.historyLoadedForFirstTime = YES;

		[self notifyViewFinishedLoadingHistory];

		[self.backingView redrawViewIfNeeded];
	};

	TVCLogControllerPrintingBlock operationBlock = ^(id operation) {
		NSDate *limitToDate = [NSDate dateWithTimeIntervalSince1970:self.viewLoadedTimestamp];

		[TVCLogControllerHistoricLogSharedInstance()
		 fetchEntriesForItem:self.associatedItem
				   ascending:NO
				  fetchLimit:100
				 limitToDate:limitToDate
		 withCompletionBlock:^(NSArray<TVCLogLine *> *objects) {
				if ([operation isCancelled]) {
					return;
				}

				reloadBlock(objects.reverseObjectEnumerator.allObjects);
		 }];
	};

	_enqueueBlockStandalone(operationBlock)
}

- (void)reloadTheme
{
	XRPerformBlockAsynchronouslyOnMainQueue(^{
		[self _reloadTheme];
	});
}

- (void)_reloadTheme
{
	if (self.terminating) {
		return;
	}

	if (self.reloadingTheme) {
		return;
	}

	/* Even if the user has never loaded their history, we force this
	 flag to YES when reloading theme. We do not want history to be
	 displayed as historic when playing it back after a reload. */
	self.historyLoadedForFirstTime = YES;

	self.reloadingTheme = YES;

	[self clearWithReset:NO];

	self.reloadingTheme = NO;
}

- (NSString *)messageBufferSessionIndicatorWithMessage:(NSString *)message
{
	NSParameterAssert(message != nil);

	NSDictionary *templateAttributes = @{
		@"message" : message
	};

	return [TVCLogRenderer renderTemplateNamed:@"messageBufferSessionIndicator" attributes:templateAttributes];
}

#pragma mark -
#pragma mark Utilities

- (void)jumpToCurrentSession
{
	NSString *lineNumber = self.newestLineNumberFromPreviousSession;

	if (lineNumber == nil) {
		lineNumber = self.oldestLineNumber;
	}

	if (lineNumber == nil) {
		return;
	}

	[self jumpToLine:lineNumber];
}

- (void)jumpToPresent
{
	NSString *lineNumber = self.newestLineNumber;

	if (lineNumber == nil) {
		lineNumber = self.newestLineNumberFromPreviousSession;
	}

	if (lineNumber == nil) {
		return;
	}

	[self jumpToLine:lineNumber];
}

- (void)jumpToLine:(NSString *)lineNumber
{
	[self jumpToLine:lineNumber completionHandler:nil];
}

- (void)jumpToLine:(NSString *)lineNumber completionHandler:(void (^ _Nullable)(BOOL result))completionHandler
{
	NSParameterAssert(lineNumber != nil);

	/* Jumping to line chains callback functinos which may take time to load.
	 We do not want invoke the completion handler until we know for certain
	 whether the line was jumped to. We therefore change the completion
	 handler and call it from a bridged function when we are finished. */
	if (completionHandler) {
		[self.jumpToLineCallbacks setObject:completionHandler forKey:lineNumber];
	}

	[self.backingView evaluateFunction:@"Textual.jumpToLine" withArguments:@[lineNumber]];
}

- (void)notifyDidBecomeVisible /* When the view is switched to */
{
	[self _evaluateFunction:@"_Textual.notifyDidBecomeVisible" withArguments:nil];

	[self maybeReloadHistory];

	[self.backingView restoreScrollerPosition];

	[self.backingView enableOffScreenUpdates];

	[self.backingView redrawViewIfNeeded];
}

- (void)notifySelectionChanged
{
	[self _evaluateFunction:@"_Textual.notifySelectionChanged" withArguments:@[@(self.selected)]];
}

- (void)notifyDidBecomeHidden
{
	[self _evaluateFunction:@"_Textual.notifyDidBecomeHidden" withArguments:nil];

	[self.backingView saveScrollerPosition];

	[self.backingView disableOffScreenUpdates];
}

- (void)notifyViewFinishedLoadingHistory
{
	[self _evaluateFunction:@"_Textual.viewFinishedLoadingHistory" withArguments:nil];
}

- (void)changeTextSize:(BOOL)bigger
{
	double sizeMultiplier = self.attachedWindow.textSizeMultiplier;

	[self _evaluateFunction:@"Textual.changeTextSizeMultiplier" withArguments:@[@(sizeMultiplier)]];

	[self _evaluateFunction:@"Textual.viewFontSizeChanged" withArguments:@[@(bigger)]];
}

- (void)changeScrollbackLimit
{
	NSUInteger scrollbackLimit = [TPCPreferences scrollbackVisibleLimit];

	[self _evaluateFunction:@"_MessageBuffer.setBufferLimit" withArguments:@[@(scrollbackLimit)]];
}

#pragma mark -
#pragma mark Plugins

- (void)notifyJumpToLine:(NSString *)lineNumber successful:(BOOL)successful scrolledToBottom:(BOOL)scrolledToBottom
{
	NSParameterAssert(lineNumber != nil);

	/* The Objective-C based automatic scroller relies on notifications of
	 bounds and frame changes to know when a WebView scrolls. If the WebView
	 is offscreen, then we have no way to know when a jump occurs because
	 these notifications are not received. To workaround this, the JavaScript
	 passes the scrolledToBottom argument. The Objective-C automatic scroller
	 can then be passed this argument to know whether to perform automatic
	 scrolling when the view becomes visible. */
	if (successful) {
		[self.backingView resetScrollerPositionTo:scrolledToBottom];
	}

	void (^callbackHandler)(BOOL) = [self.jumpToLineCallbacks objectForKey:lineNumber];

	if (callbackHandler == nil) {
		return;
	}

	/* Remove callback handler first incase the callback handler
	 tries to jump to same line number again for some reason. */
	[self.jumpToLineCallbacks removeObjectForKey:lineNumber];

	callbackHandler(successful);
}

- (void)notifyLinesAddedToView:(NSArray<NSString *> *)lineNumbers
{
	NSParameterAssert(lineNumbers != nil);

	if (self.loaded == NO || self.terminating) {
		return;
	}

	self.activeLineCount += lineNumbers.count;

	if ([sharedPluginManager() supportsFeature:THOPluginItemSupportsNewMessagePostedEvent] == NO) {
		return;
	}

	for (NSString *lineNumber in lineNumbers) {
		[THOPluginDispatcher dequeueDidPostNewMessageWithLineNumber:lineNumber forViewController:self];
	}
}

- (void)notifyLinesRemovedFromView:(NSArray<NSString *> *)lineNumbers
{
	NSParameterAssert(lineNumbers != nil);

	if (self.loaded == NO || self.terminating) {
		return;
	}

	self.activeLineCount -= lineNumbers.count;
}

- (void)notifyHistoricLogWillDeleteLines:(NSArray<NSString *> *)lineNumbers
{
	NSParameterAssert(lineNumbers != nil);

	/* It is possible for this method to be invoked before loaded is YES
	 such as when performing a clear. */
	if (/* self.loaded == NO || */ self.terminating) {
		return;
	}

	@synchronized(self.highlightedLineNumbers) {
		[self.highlightedLineNumbers removeObjectsInArray:lineNumbers];
	}
}

#pragma mark -
#pragma mark Inline Media

- (void)processingInlineMediaPayloadSucceeded:(ICLPayload *)payload
{

- (void)processingInlineMediaPayload:(ICLPayload *)payload failedWithError:(NSError *)error
}

{
	LogToConsoleError("Processing request for '%@' failed with error: %@",
		uniqueIdentifier, error.localizedDescription);
}

#pragma mark -
#pragma mark Manage Highlights

- (NSUInteger)numberOfLines
{
	return self.activeLineCount;
}

- (BOOL)highlightAvailable:(BOOL)previous
{
	if (self.loaded == NO || self.terminating) {
		return NO;
	}

	@synchronized(self.highlightedLineNumbers) {
		return (self.highlightedLineNumbers.count > 0);
	}
}

- (void)nextHighlight
{
	if (self.loaded == NO || self.terminating) {
		return;
	}
	
	@synchronized(self.highlightedLineNumbers) {
		if (self.highlightedLineNumbers.count == 0) {
			return;
		}

		if ([self.highlightedLineNumbers containsObject:self.lastVisitedHighlight]) {
			NSUInteger hli_ci = [self.highlightedLineNumbers indexOfObject:self.lastVisitedHighlight];

			if (hli_ci == (self.highlightedLineNumbers.count - 1)) {
				/* Circle around back to the beginning of the list. */
				self.lastVisitedHighlight = self.highlightedLineNumbers[0];
			} else {
				self.lastVisitedHighlight = self.highlightedLineNumbers[(hli_ci + 1)];
			}
		} else {
			self.lastVisitedHighlight = self.highlightedLineNumbers[0];
		}

		[self jumpToLine:self.lastVisitedHighlight];
	}
}

- (void)previousHighlight
{
	if (self.loaded == NO || self.terminating) {
		return;
	}

	@synchronized(self.highlightedLineNumbers) {
		if (self.highlightedLineNumbers.count == 0) {
			return;
		}

		if ([self.highlightedLineNumbers containsObject:self.lastVisitedHighlight]) {
			NSInteger hli_ci = [self.highlightedLineNumbers indexOfObject:self.lastVisitedHighlight];

			if (hli_ci == 0) {
				/* Circle around back to the end of the list. */
				self.lastVisitedHighlight = self.highlightedLineNumbers[(self.highlightedLineNumbers.count - 1)];
			} else {
				self.lastVisitedHighlight = self.highlightedLineNumbers[(hli_ci - 1)];
			}
		} else {
			self.lastVisitedHighlight = self.highlightedLineNumbers[0];
		}

		[self jumpToLine:self.lastVisitedHighlight];
	}
}

- (void)clearWithReset:(BOOL)clearWithReset
{
	if (self.terminating) {
		return;
	}

	[self.printingQueue cancelOperationsForViewController:self];

	if (clearWithReset) {
		[self historicLogResetChannel];
	}
	
	@synchronized(self.highlightedLineNumbers) {
		[self.highlightedLineNumbers removeAllObjects];
	}
	
	self.activeLineCount = 0;

	self.lastVisitedHighlight = nil;

	self.oldestLineNumber = nil;
	self.newestLineNumber = nil;

	self.loaded = NO;

	self.reloadingHistory = NO;

	self.historyLoaded = NO;

	if (self.backingView.isUsingWebKit2 != [TPCPreferences webKit2Enabled]) {
		[self rebuildBackingView];
	}

	[self loadInitialDocument];
}

- (void)clear
{
	if (self.terminating) {
		return;
	}

	[self clearWithReset:YES];
}

- (void)clearBackingView
{
	if (self.terminating) {
		return;
	}

	[self rebuildBackingView];

	[self clearWithReset:YES];
}

#pragma mark -
#pragma mark History

- (void)renderLogLinesBeforeLineNumber:(NSString *)lineNumber maximumNumberOfLines:(NSUInteger)maximumNumberOfLines completionBlock:(void (^)(NSArray<NSDictionary<NSString *, id> *> *))completionBlock
{
	[self _renderLogLinesAfter:NO lineNumber:lineNumber maximumNumberOfLines:maximumNumberOfLines completionBlock:completionBlock];
}

- (void)renderLogLinesAfterLineNumber:(NSString *)lineNumber maximumNumberOfLines:(NSUInteger)maximumNumberOfLines completionBlock:(void (^)(NSArray<NSDictionary<NSString *, id> *> *))completionBlock
{
	[self _renderLogLinesAfter:YES lineNumber:lineNumber maximumNumberOfLines:maximumNumberOfLines completionBlock:completionBlock];
}

- (void)_renderLogLinesAfter:(BOOL)after lineNumber:(NSString *)lineNumber maximumNumberOfLines:(NSUInteger)maximumNumberOfLines completionBlock:(void (^)(NSArray<NSDictionary<NSString *, id> *> *))completionBlock
{
	NSParameterAssert(lineNumber != nil);
	NSParameterAssert(maximumNumberOfLines > 0);
	NSParameterAssert(completionBlock != nil);

	TVCLogControllerPrintingBlock operationBlock = ^(id operation) {
		void (^historicLogCompletionBlock)(NSArray *) = ^(NSArray<TVCLogLine *> *entries) {
			if ([operation isCancelled]) {
				return;
			}

			[self _renderLogLinesAfterLineNumberPostFlight:entries completionBlock:completionBlock];
		};

		if (after == NO) {
			[TVCLogControllerHistoricLogSharedInstance()
			 fetchEntriesForItem:self.associatedItem
		  beforeUniqueIdentifier:lineNumber
					  fetchLimit:maximumNumberOfLines
					 limitToDate:nil
			 withCompletionBlock:historicLogCompletionBlock];
		} else {
			[TVCLogControllerHistoricLogSharedInstance()
			 fetchEntriesForItem:self.associatedItem
		   afterUniqueIdentifier:lineNumber
					  fetchLimit:maximumNumberOfLines
					 limitToDate:nil
			 withCompletionBlock:historicLogCompletionBlock];
		}
	};

	_enqueueBlockStandalone(operationBlock)
}

- (void)renderLogLinesAfterLineNumber:(NSString *)lineNumberAfter beforeLineNumber:(NSString *)lineNumberBefore maximumNumberOfLines:(NSUInteger)maximumNumberOfLines completionBlock:(void (^)(NSArray<NSDictionary<NSString *,id> *> * _Nonnull))completionBlock
{
	NSParameterAssert(lineNumberAfter != nil);
	NSParameterAssert(lineNumberBefore != nil);
	NSParameterAssert(completionBlock != nil);

	TVCLogControllerPrintingBlock operationBlock = ^(id operation) {
		void (^historicLogCompletionBlock)(NSArray *) = ^(NSArray<TVCLogLine *> *entries) {
			if ([operation isCancelled]) {
				return;
			}

			[self _renderLogLinesAfterLineNumberPostFlight:entries completionBlock:completionBlock];
		};

		[TVCLogControllerHistoricLogSharedInstance()
			 fetchEntriesForItem:self.associatedItem
		   afterUniqueIdentifier:lineNumberAfter
		  beforeUniqueIdentifier:lineNumberBefore
					  fetchLimit:maximumNumberOfLines
			 withCompletionBlock:historicLogCompletionBlock];
	};

	_enqueueBlockStandalone(operationBlock)
}

- (void)renderLogLineAtLineNumber:(NSString *)lineNumber numberOfLinesBefore:(NSUInteger)numberOfLinesBefore numberOfLinesAfter:(NSUInteger)numberOfLinesAfter completionBlock:(void (^)(NSArray<NSDictionary<NSString *,id> *> * _Nonnull))completionBlock
{
	NSParameterAssert(lineNumber != nil);
	NSParameterAssert(completionBlock != nil);

	TVCLogControllerPrintingBlock operationBlock = ^(id operation) {
		void (^historicLogCompletionBlock)(NSArray *) = ^(NSArray<TVCLogLine *> *entries) {
			if ([operation isCancelled]) {
				return;
			}

			[self _renderLogLinesAfterLineNumberPostFlight:entries completionBlock:completionBlock];
		};

		[TVCLogControllerHistoricLogSharedInstance()
			 fetchEntriesForItem:self.associatedItem
		    withUniqueIdentifier:lineNumber
			    beforeFetchLimit:numberOfLinesBefore
			     afterFetchLimit:numberOfLinesAfter
					 limitToDate:nil
			 withCompletionBlock:historicLogCompletionBlock];
	};

	_enqueueBlockStandalone(operationBlock)
}

- (void)_renderLogLinesAfterLineNumberPostFlight:(NSArray<TVCLogLine *> *)logLines completionBlock:(void (^)(NSArray<NSDictionary<NSString *, id> *> *))completionBlock
{
	NSParameterAssert(logLines != nil);
	NSParameterAssert(completionBlock != nil);

	NSMutableArray<NSDictionary<NSString *, id> *> *renderedLogLines = [NSMutableArray arrayWithCapacity:logLines.count];

	NSMutableArray<THOPluginDidPostNewMessageConcreteObject *> *pluginObjects = nil;

	for (TVCLogLine *logLine in logLines) {
		/* Render result info HTML */
		NSDictionary<NSString *, id> *resultInfo = nil;

		NSString *html = [self renderLogLine:logLine resultInfo:&resultInfo];

		if (html == nil) {
			LogToConsoleError("Failed to render log line %{public}@", logLine.description);

			continue;
		}

		/* Record information about rendering */
		NSString *lineNumber = logLine.uniqueIdentifier;

		[renderedLogLines addObject:@{
			@"lineNumber" : lineNumber,
			@"html" : html,
			@"timestamp" : @(logLine.receivedAt.timeIntervalSince1970)
	    }];

		/* Add "Current Session" message */
		if ([lineNumber isEqualToString:self.newestLineNumberFromPreviousSession]) {
			NSString *html = [self messageBufferSessionIndicatorWithMessage:TXTLS(@"IRC[1127]")];

			[renderedLogLines addObject:@{
				  @"html" : html
		    }];
		}

		/* Add reference to plugin concrete object */
		THOPluginDidPostNewMessageConcreteObject *pluginObject = resultInfo[@"pluginConcreteObject"];

		if (pluginObject) {
			if (pluginObjects == nil) {
				pluginObjects = [NSMutableArray array];
			}

			[pluginObjects addObject:pluginObject];
		}
	}

	/* Inform plugins of new content */
	for (THOPluginDidPostNewMessageConcreteObject *pluginObject in pluginObjects) {
		pluginObject.isProcessedInBulk = YES;

		[THOPluginDispatcher enqueueDidPostNewMessage:pluginObject];
	}

	/* Finish */
	completionBlock([renderedLogLines copy]);
}

#pragma mark -
#pragma mark Print

- (void)print:(TVCLogLine *)logLine
{
	[self print:logLine completionBlock:NULL];
}

- (void)print:(TVCLogLine *)logLine completionBlock:(nullable TVCLogControllerPrintOperationCompletionBlock)completionBlock
{
	NSParameterAssert(logLine != nil);

	if (self.terminating) {
		return;
	}

	if ([logLine isKindOfClass:[TVCLogLineMutable class]]) {
		logLine = [logLine copy];
	}

	TVCLogControllerPrintingBlock printBlock = ^(id operation) {
		NSDictionary<NSString *, id> *resultInfo = nil;
		
		NSString *html = [self renderLogLine:logLine resultInfo:&resultInfo];

		if (html == nil) {
			LogToConsoleError("Failed to render log line %{public}@", logLine.description);

			return;
		}

		NSString *lineNumber = logLine.uniqueIdentifier;

		NSSet<IRCChannelUser *> *listOfUsers = resultInfo[TVCLogRendererResultsListOfUsersFoundAttribute];

		BOOL inlineMediaEnabled = [resultInfo boolForKey:@"inlineMediaEnabled"];
		
		BOOL highlighted = [resultInfo boolForKey:TVCLogRendererResultsKeywordMatchFoundAttribute];

		THOPluginDidPostNewMessageConcreteObject *pluginObject = resultInfo[@"pluginConcreteObject"];
		
		XRPerformBlockAsynchronouslyOnMainQueue(^{
			if (self.terminating) {
				return;
			}

			if (self.oldestLineNumber == nil) {
				self.oldestLineNumber = lineNumber;
			}

			self.newestLineNumber = lineNumber;

			IRCClient *client = self.associatedClient;
			IRCChannel *channel = self.associatedChannel;

			if (highlighted) {
				@synchronized(self.highlightedLineNumbers) {
					[self.highlightedLineNumbers addObject:lineNumber];
				}

				[client cacheHighlightInChannel:channel withLogLine:logLine];
			}

			if (pluginObject) {
				[THOPluginDispatcher enqueueDidPostNewMessage:resultInfo[@"pluginConcreteObject"]];
			}

			[self appendToDocumentBody:html withLineNumbers:@[lineNumber]];

			/* Begin processing inline media */
			/* We go through the inline media list here and pass to the loader now so
			 that we know the links have hit the WebView before we even try loading them. */
			if (inlineMediaEnabled) {
				NSArray<AHHyperlinkScannerResult *> *listOfLinks = resultInfo[TVCLogRendererResultsListOfLinksInBodyAttribute];

				[listOfLinks enumerateObjectsUsingBlock:^(AHHyperlinkScannerResult *link, NSUInteger index, BOOL *stop) {
					[TVCLogControllerInlineMediaSharedInstance()
							 processAddress:link.stringValue
					   withUniqueIdentifier:link.uniqueIdentifier
								    forItem:channel];
				}];
			}

			/* Log this log line */
			/* If the channel is encrypted, then we refuse to write to
			 the actual historic log so there is no trace of the chatter
			 on the disk in the form of an unencrypted cache file. */
			/* Doing it this way does break the ability to reload chatter
			 in the view as well as playback on restart, but the added
			 security can be seen as a bonus. */
			if (self.encrypted == NO) {
				[TVCLogControllerHistoricLogSharedInstance() writeNewEntryWithLogLine:logLine forItem:self.associatedItem];
			}

			/* Redraw view if needed */
			[self.backingView redrawViewIfNeeded];

			/* Using informationi provided by conversation tracking we can update 
			 our internal array of favored nicknames for nick completion. */
			if (logLine.memberType == TVCLogLineMemberLocalUserType) {
				[listOfUsers.allObjects makeObjectsPerformSelector:@selector(outgoingConversation)];
			} else {
				[listOfUsers.allObjects makeObjectsPerformSelector:@selector(conversation)];
			}

			if (completionBlock == nil) {
				return;
			}

			 TVCLogControllerPrintOperationContext *contextObject =
			[TVCLogControllerPrintOperationContext new];

			contextObject.client = client;
			contextObject.channel = channel;
			contextObject.highlight = highlighted;
			contextObject.logLine = logLine;
			contextObject.lineNumber = lineNumber;

			completionBlock(contextObject);
		});
	};

	_enqueueBlock(printBlock)
}

- (nullable NSString *)renderLogLine:(TVCLogLine *)logLine resultInfo:(NSDictionary<NSString *, id> ** _Nullable)resultInfo
{
	NSParameterAssert(logLine != nil);

	// ************************************************************************** /

	TVCLogLineType lineType = logLine.lineType;

	NSString *lineTypeString = logLine.lineTypeString;

	BOOL renderLinks = ([[TLOLinkParser bannedLineTypes] containsObject:lineTypeString] == NO);

	NSMutableDictionary<NSString *, id> *rendererAttributes = [NSMutableDictionary dictionary];

	if (logLine.rendererAttributes != nil) {
		[rendererAttributes addEntriesFromDictionary:logLine.rendererAttributes];
	}

	[rendererAttributes maybeSetObject:logLine.excludeKeywords forKey:TVCLogRendererConfigurationExcludedKeywordsAttribute];
	[rendererAttributes maybeSetObject:logLine.highlightKeywords forKey:TVCLogRendererConfigurationHighlightKeywordsAttribute];
	
	[rendererAttributes setBool:renderLinks forKey:TVCLogRendererConfigurationRenderLinksAttribute];

	[rendererAttributes setUnsignedInteger:logLine.lineType forKey:TVCLogRendererConfigurationLineTypeAttribute];
	[rendererAttributes setUnsignedInteger:logLine.memberType forKey:TVCLogRendererConfigurationMemberTypeAttribute];

	NSDictionary<NSString *, id> *rendererResults = nil;

	NSString *renderedBody =
	[TVCLogRenderer renderBody:logLine.messageBody
			 forViewController:self
				withAttributes:rendererAttributes
					resultInfo:&rendererResults];

	if (renderedBody == nil) {
		return nil;
	}

	NSMutableDictionary<NSString *, id> *resultInfoTemp = nil;

	if (resultInfo) {
		resultInfoTemp = [rendererResults mutableCopy];
	}

	BOOL highlighted = [rendererResults boolForKey:TVCLogRendererResultsKeywordMatchFoundAttribute];

	BOOL inlineMedia =
		(self.inlineMediaEnabledForView &&
		 (lineType == TVCLogLinePrivateMessageType || lineType == TVCLogLineActionType));

	// ************************************************************************** /

	NSMutableDictionary<NSString *, id> *pathAttributes = [NSMutableDictionary new];

	pathAttributes[@"activeStyleAbsolutePath"] = self.baseURL.path;
	
	pathAttributes[@"applicationResourcePath"] = [TPCPathInfo applicationResources];

	NSMutableDictionary<NSString *, id> *templateAttributes = [pathAttributes mutableCopy];

	// ---- //

	templateAttributes[@"timestamp"] = @(logLine.receivedAt.timeIntervalSince1970);

	templateAttributes[@"formattedTimestamp"] = logLine.formattedTimestamp;

	if ([TPCPreferences generateLocalizedTimestampTemplateToken]) {
		templateAttributes[@"localizedTimestamp"] = TXFormatDateLongStyle(logLine.receivedAt, NO);
	}

	// ---- //

	NSString *nickname = [logLine formattedNicknameInChannel:self.associatedChannel];

	if (nickname.length == 0) {
		templateAttributes[@"isNicknameAvailable"] = @(NO);
	} else {
		templateAttributes[@"isNicknameAvailable"] = @(YES);
		
		templateAttributes[@"nicknameColorNumber"] = logLine.nicknameColorStyle;
		templateAttributes[@"nicknameColorStyle"] = logLine.nicknameColorStyle;

		templateAttributes[@"nicknameColorStyleOverride"] = @(logLine.nicknameColorStyleOverride);

		templateAttributes[@"nicknameColorHashingEnabled"] = @([TPCPreferences disableNicknameColorHashing] == NO);

		templateAttributes[@"nicknameColorHashingIsStyleBased"] = @(themeSettings().nicknameColorStyle != TPCThemeSettingsNicknameColorLegacyStyle);
		
		templateAttributes[@"formattedNickname"] = nickname.trim;
		
		templateAttributes[@"nickname"]	= logLine.nickname;
		templateAttributes[@"nicknameType"]	= logLine.memberTypeString;
	}

	// ---- //

	templateAttributes[@"lineType"] = lineTypeString;

	templateAttributes[@"command"] = logLine.command;
	templateAttributes[@"rawCommand"] = logLine.command; // Legacy key

	// ---- //

	NSString *classAttribute = nil;

	if (lineType == TVCLogLinePrivateMessageType || lineType == TVCLogLineActionType || lineType == TVCLogLineNoticeType) {
		classAttribute = @"text";
	} else {
		classAttribute = @"event";
	}

	templateAttributes[@"lineClassAttributeRepresentation"] = classAttribute;

	// ---- //

	if (highlighted) {
		templateAttributes[@"highlightAttributeRepresentation"] = @"true";
	} else {
		templateAttributes[@"highlightAttributeRepresentation"] = @"false";
	}

	// ---- //

	templateAttributes[@"message"] = logLine.messageBody;

	templateAttributes[@"formattedMessage"]	= renderedBody;

	templateAttributes[@"isHighlight"] = @(highlighted);

	templateAttributes[@"isRemoteMessage"] = @(logLine.memberType == TVCLogLineMemberNormalType);

	// ---- //

	if (logLine.isEncrypted) {
		templateAttributes[@"isEncrypted"] = @(YES);

		templateAttributes[@"encryptedMessageLockTemplate"] =
		[TVCLogRenderer renderTemplateNamed:@"encryptedMessageLock" attributes:pathAttributes];
	}

	// ---- //

	NSString *serverName = self.associatedClient.networkNameAlt;
	
	if (serverName) {
		templateAttributes[@"configuredServerName"] = serverName;
	}
	
	// ---- //

	templateAttributes[@"inlineMediaEnabled"] = @(inlineMedia);

	templateAttributes[@"lineNumber"] = logLine.uniqueIdentifier;

	templateAttributes[@"lineRenderTime"] = @([NSDate timeIntervalSince1970]);

	// ************************************************************************** /

	if (resultInfoTemp) {
		if (self.inlineMediaEnabledForView == NO ||
			(lineType != TVCLogLinePrivateMessageType && lineType != TVCLogLineActionType))
		{
			resultInfoTemp[@"inlineMediaEnabled"] = @(NO);
		} else {
			resultInfoTemp[@"inlineMediaEnabled"] = @(YES);
		}
		
		if ([sharedPluginManager() supportsFeature:THOPluginItemSupportsNewMessagePostedEvent]) {
			NSArray<AHHyperlinkScannerResult *> *listOfLinks = rendererResults[TVCLogRendererResultsListOfLinksInBodyAttribute];

			 THOPluginDidPostNewMessageConcreteObject *pluginConcreteObject =
			[THOPluginDidPostNewMessageConcreteObject new];

			pluginConcreteObject.keywordMatchFound = highlighted;

			pluginConcreteObject.lineType = lineType;
			pluginConcreteObject.memberType = logLine.memberType;

			pluginConcreteObject.senderNickname = logLine.nickname;

			pluginConcreteObject.receivedAt = logLine.receivedAt;

			pluginConcreteObject.lineNumber = logLine.uniqueIdentifier;

			pluginConcreteObject.messageContents = rendererResults[TVCLogRendererResultsOriginalBodyWithoutEffectsAttribute];

			pluginConcreteObject.listOfHyperlinks = listOfLinks;

			pluginConcreteObject.listOfUsers = rendererResults[TVCLogRendererResultsListOfUsersFoundAttribute];

			resultInfoTemp[@"pluginConcreteObject"] = pluginConcreteObject;
		}
	}

	// ************************************************************************** /

	if ( resultInfo) {
		*resultInfo = resultInfoTemp;
	}

	// ************************************************************************** /

	GRMustacheTemplate *template = [themeSettings() templateWithLineType:lineType];

	NSString *html = [TVCLogRenderer renderTemplate:template attributes:templateAttributes];

	return html;
}

#pragma mark -
#pragma mark Initial Document

- (BOOL)usesCustomScrollers
{
	NSScrollerStyle preferredScrollerStyle = [NSScroller preferredScrollerStyle];

	BOOL onlyShowDuringScrolling = (preferredScrollerStyle == NSScrollerStyleOverlay);

	BOOL usesCustomScrollers = [TPCPreferences themeChannelViewUsesCustomScrollers];

	BOOL usingWebKit2 = self.backingView.isUsingWebKit2;

	return (onlyShowDuringScrolling == NO && usesCustomScrollers && usingWebKit2);
}

- (NSString *)initialDocument
{
	NSMutableDictionary *templateTokens = [self generateOverrideStyle];

	templateTokens[@"activeStyleAbsolutePath"] = self.baseURL.path;
	
	templateTokens[@"applicationResourcePath"] = [TPCPathInfo applicationResources];

	templateTokens[@"applicationTemplatesPath"] = themeSettings().applicationTemplateRepositoryPath;

	templateTokens[@"cacheToken"] = themeController().cacheToken;

    templateTokens[@"configuredServerName"] = self.associatedClient.networkNameAlt;

	templateTokens[@"isReloadingStyle"] = @(self.reloadingTheme);

	templateTokens[@"operatingSystemVersion"] = [XRSystemInformation systemStandardVersion];

	templateTokens[@"sidebarInversionIsEnabled"] = @([TPCPreferences invertSidebarColors]);

	templateTokens[@"userConfiguredTextEncoding"] = [NSString charsetRepFromStringEncoding:self.associatedClient.config.primaryEncoding];

	templateTokens[@"usesCustomScrollers"] = @([self usesCustomScrollers]);

	if (self.associatedChannel) {
		templateTokens[@"isChannelView"] = @(self.associatedChannel.isChannel);
        templateTokens[@"isPrivateMessageView"] = @(self.associatedChannel.isPrivateMessage);
		templateTokens[@"isUtilityView"] = @(self.associatedChannel.isUtility);

		templateTokens[@"channelName"] = self.associatedChannel.name;
		
		templateTokens[@"viewTypeToken"] = self.associatedChannel.channelTypeString;
	} else {
		templateTokens[@"viewTypeToken"] = @"server";
	}

	if ([TPCPreferences rightToLeftFormatting]) {
		templateTokens[@"textDirectionToken"] = @"rtl";
	} else {
		templateTokens[@"textDirectionToken"] = @"ltr";
	}

	return [TVCLogRenderer renderTemplateNamed:@"baseLayout" attributes:templateTokens];
}

- (NSMutableDictionary<NSString *, id> *)generateOverrideStyle
{
	NSMutableDictionary<NSString *, id> *templateTokens = [NSMutableDictionary dictionary];

	// ---- //

	NSFont *channelFont = themeSettings().themeChannelViewFont;

	if (channelFont == nil) {
		channelFont = [TPCPreferences themeChannelViewFont];
	}

	templateTokens[@"userConfiguredFontName"] =   channelFont.fontName;
	templateTokens[@"userConfiguredFontSize"] = @(channelFont.pointSize * (72.0 / 96.0));

	// ---- //

	double indentOffset = themeSettings().indentationOffset;

	if (round(indentOffset) < 0.0 || [TPCPreferences rightToLeftFormatting]) {
		templateTokens[@"nicknameIndentationAvailable"] = @(NO);
	} else {
		templateTokens[@"nicknameIndentationAvailable"] = @(YES);
		
		NSString *timeFormat = themeSettings().themeTimestampFormat;
		
		if (timeFormat == nil) {
			timeFormat = [TPCPreferences themeTimestampFormat];
		}

		NSString *time = TXFormattedTimestamp([NSDate date], timeFormat);

		NSSize textSize = [time sizeWithAttributes:@{NSFontAttributeName : channelFont}];

		templateTokens[@"predefinedTimestampWidth"] = @(textSize.width + indentOffset);
	}

	// ---- //

	return templateTokens;
}

#pragma mark -
#pragma mark LogView Delegate

- (void)logViewWebViewFinishedLoading
{
	if (self.loaded == NO) {
		self.loaded = YES;
	} else {
		return;
	}

	self.viewLoadedTimestamp = [NSDate timeIntervalSince1970];

	NSString *viewType = nil;

	if (self.associatedChannel) {
		viewType = self.associatedChannel.channelTypeString;
	} else {
		viewType = @"server";
	}

	[self _evaluateFunction:@"Textual.viewInitiated" withArguments:@[
		 NSDictionaryNilValue(viewType),
		 NSDictionaryNilValue(self.associatedClient.uniqueIdentifier),
		 NSDictionaryNilValue(self.associatedChannel.uniqueIdentifier),
		 NSDictionaryNilValue(self.associatedChannel.name)
	]];

	double textSizeMultiplier = self.attachedWindow.textSizeMultiplier;

	NSUInteger scrollbackLimit = [TPCPreferences scrollbackVisibleLimit];

	[self _evaluateFunction:@"_Textual.viewFinishedLoading"
			  withArguments:
	 @[
		  @{
			  @"selected" : @(self.selected),
			  @"visible" : @(self.visible),
			  @"reloadingTheme" : @(self.reloadingTheme), // TODO: Fix this always being false
			  @"textSizeMultiplier" : @(textSizeMultiplier),
			  @"scrollbackLimit" : @(scrollbackLimit)
		  }
	  ]];

	[self setInitialTopic];

	[self reloadHistory];

	[RZNotificationCenter() postNotificationName:TVCLogControllerViewFinishedLoadingNotification object:self];

	[self.printingQueue updateReadinessState:self];
}

- (void)logViewWebViewClosedUnexpectedly
{
	[self clearBackingView];
}

- (void)logViewWebViewKeyDown:(NSEvent *)e
{
	[self.attachedWindow redirectKeyDown:e];
}

- (void)logViewWebViewRecievedDropWithFile:(NSString *)filename
{
	[menuController() memberSendDroppedFilesToSelectedChannel:@[filename]];
}

@end

#pragma mark -

@implementation TVCLogControllerPrintOperationContext
@end

NS_ASSUME_NONNULL_END
