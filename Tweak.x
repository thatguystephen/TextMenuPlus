#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>

static NSString *const FSDisablePath = @"/var/mobile/textmenuplus.disable";
static NSString *const FSDebugPath = @"/var/mobile/textmenuplus.debug";
static NSString *const FSPropertyListPrefix = @"com.schlub51.textmenuplus.";
static NSString *const FSStylesPath = @"/var/jb/Library/Application Support/TextMenuPlus/com.schlub51.textmenuplus.styles.plist";

static char FSAssociatedMarkerKey;
static char FSNativeIconConstraintsKey;
static UIView *FSPanelOverlay = nil;
static __weak id FSLastTextTarget = nil;
static NSTimeInterval FSLastAutoPanelTime = 0;
static NSInteger const FSMenuIconTag = 0x46534943;

static NSArray *FSStyleDefinitions(void);
static NSDictionary *FSStyleDefinition(NSString *name);
static NSString *FSStripTextMenuPlusCombineMarks(NSString *text);
static NSDictionary *FSReverseStyleMap(void);
static NSString *FSPlainTextFromStyledText(NSString *text);
static NSString *FSPlainTextForTransform(NSString *text);
static NSString *FSApplyStyleMap(NSString *text, NSDictionary *map);
static NSString *FSApplyCombineStyle(NSString *text, NSString *combine);
static NSString *FSRenderTextWithState(NSString *plainText, NSString *styleName, NSString *combineName);
static NSString *FSApplyTextTransformPreservingState(NSString *text, NSString *(^transform)(NSString *plainText));
static void FSDismissPanel(void);
static void FSShowPanelForTarget(id target);
static NSString *FSTitleForElement(id element);
static SEL FSActionForElement(id element);
static NSString *FSMarkerFromSender(id sender);

static NSString *FSLogPath(void) {
	NSString *temporaryDirectory = NSTemporaryDirectory();
	if(temporaryDirectory.length == 0) {
		temporaryDirectory = @"/tmp/";
	}
	return [temporaryDirectory stringByAppendingPathComponent:@"textmenuplus.log"];
}

static BOOL FSDisabled(void) {
	return [[NSFileManager defaultManager] fileExistsAtPath:FSDisablePath];
}

static BOOL FSProcessAllowed(void) {
	NSString *bundleIdentifier = [[NSBundle mainBundle] bundleIdentifier] ?: @"";
	NSString *processName = [[NSProcessInfo processInfo] processName] ?: @"";
	static NSSet *excludedBundleIdentifiers = nil;
	static NSSet *excludedProcessNames = nil;
	static dispatch_once_t onceToken;
	dispatch_once(&onceToken, ^{
		excludedBundleIdentifiers = [NSSet setWithObjects:
			@"com.apple.springboard",
			nil];
		excludedProcessNames = [NSSet setWithObjects:
			@"SpringBoard",
			@"backboardd",
			nil];
	});
	return ![excludedBundleIdentifiers containsObject:bundleIdentifier] &&
	       ![excludedProcessNames containsObject:processName];
}

static BOOL FSShouldRun(void) {
	return !FSDisabled() && FSProcessAllowed();
}

static void FSLog(NSString *message) {
	if(!FSShouldRun()) {
		return;
	}
	if(![[NSFileManager defaultManager] fileExistsAtPath:FSDebugPath]) {
		return;
	}
	NSString *processName = [[NSProcessInfo processInfo] processName] ?: @"unknown";
	NSString *line = [NSString stringWithFormat:@"%@ [%@] %@\n", [NSDate date], processName, message];
	NSData *data = [line dataUsingEncoding:NSUTF8StringEncoding];
	NSString *logPath = FSLogPath();
	if(![[NSFileManager defaultManager] fileExistsAtPath:logPath]) {
		[data writeToFile:logPath atomically:YES];
		return;
	}
	NSFileHandle *handle = [NSFileHandle fileHandleForWritingAtPath:logPath];
	[handle seekToEndOfFile];
	[handle writeData:data];
	[handle closeFile];
}

static void FSForceVerticalAxis(id object, NSString *source) {
	(void)source;
	if([object respondsToSelector:@selector(setAxis:)]) {
		[object setAxis:1];
	}
}

static CGFloat FSMaxMenuHeight(CGSize containerSize) {
	CGFloat referenceHeight = containerSize.height > 0.0 ? containerSize.height : UIScreen.mainScreen.bounds.size.height;
	return MAX(180.0, MIN(280.0, floor(referenceHeight * 0.52)));
}

static void FSCollectLabels(UIView *view, NSMutableArray<UILabel *> *labels) {
	if(![view isKindOfClass:[UIView class]]) {
		return;
	}
	if([view isKindOfClass:[UILabel class]]) {
		UILabel *label = (UILabel *)view;
		if(label.text.length > 0) {
			[labels addObject:label];
		}
	}
	for(UIView *subview in view.subviews) {
		FSCollectLabels(subview, labels);
	}
}

static void FSCollectImageViews(UIView *view, NSMutableArray<UIImageView *> *imageViews) {
	if(![view isKindOfClass:[UIView class]]) {
		return;
	}
	if([view isKindOfClass:[UIImageView class]]) {
		[imageViews addObject:(UIImageView *)view];
	}
	for(UIView *subview in view.subviews) {
		FSCollectImageViews(subview, imageViews);
	}
}

static UIStackView *FSFindMenuStackView(UIView *view) {
	if(![view isKindOfClass:[UIView class]]) {
		return nil;
	}
	if([view isKindOfClass:[UIStackView class]]) {
		return (UIStackView *)view;
	}
	for(UIView *subview in view.subviews) {
		UIStackView *stackView = FSFindMenuStackView(subview);
		if(stackView != nil) {
			return stackView;
		}
	}
	return nil;
}

static NSString *FSNormalizedMenuTitle(NSString *title) {
	if(![title isKindOfClass:[NSString class]]) {
		return @"";
	}
	NSString *trimmed = [title stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
	trimmed = [trimmed stringByReplacingOccurrencesOfString:@"\u00a0" withString:@" "];
	NSArray *parts = [trimmed componentsSeparatedByCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
	NSPredicate *nonEmpty = [NSPredicate predicateWithBlock:^BOOL(NSString *part, NSDictionary *bindings) {
		(void)bindings;
		return part.length > 0;
	}];
	return [[parts filteredArrayUsingPredicate:nonEmpty] componentsJoinedByString:@" "];
}

static NSArray *FSSymbolNamesForMenuTitle(NSString *title) {
	title = FSNormalizedMenuTitle(title);
	static NSDictionary *symbolsByTitle = nil;
	static dispatch_once_t onceToken;
	dispatch_once(&onceToken, ^{
		symbolsByTitle = @{
			@"Cut": @[@"scissors"],
			@"Copy": @[@"doc.on.doc", @"doc"],
			@"Copy Clean Link": @[@"wand.and.stars", @"sparkles", @"doc.on.doc", @"doc"],
			@"Paste": @[@"doc.on.clipboard", @"doc.on.doc", @"clipboard", @"doc.plaintext", @"doc"],
			@"Paste and Search": @[@"magnifyingglass", @"safari", @"network"],
			@"Select": @[@"selection.pin.in.out", @"cursorarrow"],
			@"Select All": @[@"text.badge.checkmark", @"checkmark.circle"],
			@"Undo": @[@"arrow.uturn.backward"],
			@"Redo": @[@"arrow.uturn.forward"],
			@"Plain": @[@"textformat"],
			@"Upper": @[@"textformat.size", @"textformat"],
			@"Lower": @[@"textformat.size.smaller", @"textformat"],
			@"Caps": @[@"textformat.abc", @"textformat"],
			@"Bold": @[@"bold"],
			@"Italic": @[@"italic"],
			@"Underline": @[@"underline"],
			@"Strikethrough": @[@"strikethrough"],
			@"Strike Through": @[@"strikethrough"],
			@"Mono": @[@"curlybraces"],
			@"Format": @[@"bold", @"italic", @"underline"],
			@"Text Case": @[@"textformat", @"textformat.abc"],
			@"Indentation": @[@"increase.indent", @"decrease.indent"],
			@"Increase": @[@"increase.indent"],
			@"Decrease": @[@"decrease.indent"],
			@"Replace...": @[@"arrow.left.arrow.right", @"textformat"],
			@"Replace…": @[@"arrow.left.arrow.right", @"textformat"],
			@"Insert Drawing": @[@"pencil.tip.crop.circle", @"pencil.and.outline"],
			@"Scan Text": @[@"text.viewfinder", @"viewfinder"],
			@"Find Selection": @[@"magnifyingglass"],
			@"Look Up": @[@"book"],
			@"Translate": @[@"globe"],
			@"Search Web": @[@"safari", @"safari.fill", @"network", @"globe"],
			@"Open Link": @[@"link", @"safari"],
			@"Add to Reading List": @[@"eyeglasses", @"book"],
			@"Share…": @[@"square.and.arrow.up"]
		};
	});
	NSArray *symbols = [symbolsByTitle objectForKey:title];
	if(symbols != nil) {
		return symbols;
	}
	if([title rangeOfString:@"Paste" options:NSCaseInsensitiveSearch].location != NSNotFound &&
	   [title rangeOfString:@"Search" options:NSCaseInsensitiveSearch].location != NSNotFound) {
		return @[@"magnifyingglass", @"safari", @"network"];
	}
	return nil;
}

static UIImage *FSImageForMenuTitle(NSString *title) {
	title = FSNormalizedMenuTitle(title);
	for(NSString *symbolName in FSSymbolNamesForMenuTitle(title)) {
		UIImage *image = [UIImage systemImageNamed:symbolName];
		if(image != nil) {
			return image;
		}
	}
	return nil;
}

static void FSConstrainNativeIconView(UIImageView *imageView) {
	if(![imageView isKindOfClass:[UIImageView class]]) {
		return;
	}
	NSArray<NSLayoutConstraint *> *constraints = objc_getAssociatedObject(imageView, &FSNativeIconConstraintsKey);
	NSLayoutConstraint *width = constraints.count > 0 ? constraints[0] : nil;
	NSLayoutConstraint *height = constraints.count > 1 ? constraints[1] : nil;
	if(width == nil || height == nil) {
		imageView.translatesAutoresizingMaskIntoConstraints = NO;
		width = [imageView.widthAnchor constraintEqualToConstant:18.0];
		height = [imageView.heightAnchor constraintEqualToConstant:18.0];
		objc_setAssociatedObject(imageView, &FSNativeIconConstraintsKey, @[width, height], OBJC_ASSOCIATION_RETAIN_NONATOMIC);
	}
	imageView.translatesAutoresizingMaskIntoConstraints = NO;
	width.constant = 18.0;
	height.constant = 18.0;
	width.priority = UILayoutPriorityRequired;
	height.priority = UILayoutPriorityRequired;
	width.active = YES;
	height.active = YES;
	[imageView setContentHuggingPriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
	[imageView setContentCompressionResistancePriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
}

static void FSStyleMenuCell(UICollectionViewCell *cell) {
	if(![cell isKindOfClass:[UICollectionViewCell class]]) {
		return;
	}

	UIView *oldIconView = [cell.contentView viewWithTag:FSMenuIconTag];
	[oldIconView removeFromSuperview];

	NSMutableArray<UILabel *> *labels = [NSMutableArray array];
	FSCollectLabels(cell.contentView, labels);
	if(labels.count == 0) {
		FSCollectLabels((UIView *)cell, labels);
	}
	if(labels.count == 0) {
		return;
	}

	UILabel *titleLabel = labels.firstObject;
	for(UILabel *label in labels) {
		label.textAlignment = NSTextAlignmentLeft;
		if(label.text.length > titleLabel.text.length) {
			titleLabel = label;
		}
	}

	NSString *normalizedTitle = FSNormalizedMenuTitle(titleLabel.text);
	UIImage *symbolImage = FSImageForMenuTitle(normalizedTitle);

	UIStackView *stackView = FSFindMenuStackView(cell.contentView);
	if(stackView != nil) {
		stackView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleBottomMargin;
		stackView.spacing = symbolImage == nil ? 0.0 : 10.0;
		stackView.alignment = UIStackViewAlignmentCenter;
		stackView.distribution = UIStackViewDistributionFill;
		stackView.frame = CGRectMake(16.0,
			floor((CGRectGetHeight(cell.contentView.bounds) - 20.0) / 2.0),
			MAX(20.0, CGRectGetWidth(cell.contentView.bounds) - 28.0),
			20.0);
	}

	NSMutableArray<UIImageView *> *imageViews = [NSMutableArray array];
	FSCollectImageViews(stackView ?: cell.contentView, imageViews);
	UIImageView *nativeImageView = imageViews.firstObject;
	if(symbolImage != nil && nativeImageView != nil) {
		nativeImageView.hidden = NO;
		nativeImageView.alpha = 1.0;
		nativeImageView.image = symbolImage;
		nativeImageView.tintColor = titleLabel.textColor;
		nativeImageView.contentMode = UIViewContentModeScaleAspectFit;
		FSConstrainNativeIconView(nativeImageView);
		nativeImageView.backgroundColor = nil;
		nativeImageView.layer.borderWidth = 0.0;
		nativeImageView.layer.borderColor = nil;
	} else if(nativeImageView != nil) {
		nativeImageView.hidden = YES;
	} else if(symbolImage != nil) {
		UIImageView *fallbackImageView = [[UIImageView alloc] initWithImage:symbolImage];
		fallbackImageView.tag = FSMenuIconTag;
		fallbackImageView.tintColor = titleLabel.textColor;
		fallbackImageView.contentMode = UIViewContentModeScaleAspectFit;
		if(stackView != nil) {
			FSConstrainNativeIconView(fallbackImageView);
			[stackView insertArrangedSubview:fallbackImageView atIndex:0];
			stackView.spacing = 10.0;
		} else {
			fallbackImageView.frame = CGRectMake(16.0,
				floor((CGRectGetHeight(cell.contentView.bounds) - 18.0) / 2.0),
				18.0,
				18.0);
			fallbackImageView.autoresizingMask = UIViewAutoresizingFlexibleRightMargin | UIViewAutoresizingFlexibleTopMargin | UIViewAutoresizingFlexibleBottomMargin;
			[cell.contentView addSubview:fallbackImageView];
		}
	}

	if(stackView == nil) {
		titleLabel.translatesAutoresizingMaskIntoConstraints = YES;
		CGRect labelFrame = titleLabel.frame;
		labelFrame.origin.x = symbolImage == nil ? 16.0 : 46.0;
		labelFrame.size.width = MAX(20.0, CGRectGetWidth(cell.contentView.bounds) - labelFrame.origin.x - 12.0);
		titleLabel.frame = labelFrame;
	}
}

static void FSStyleVisibleMenuCells(UIView *rootView) {
	if(![rootView isKindOfClass:[UIView class]]) {
		return;
	}
	if([rootView isKindOfClass:[UICollectionView class]]) {
		for(UICollectionViewCell *cell in [(UICollectionView *)rootView visibleCells]) {
			FSStyleMenuCell(cell);
		}
	}
	for(UIView *subview in rootView.subviews) {
		FSStyleVisibleMenuCells(subview);
	}
}

static NSString *FSTitleForElement(id element) {
	if([element respondsToSelector:@selector(title)]) {
		return [element title] ?: @"";
	}
	return @"";
}

static SEL FSActionForElement(id element) {
	if([element respondsToSelector:@selector(action)]) {
		return [element action];
	}
	return NULL;
}

static BOOL FSElementIsCopyCommand(id element) {
	SEL action = FSActionForElement(element);
	return action == @selector(copy:) && [FSTitleForElement(element) isEqualToString:@"Copy"];
}

static BOOL FSElementIsPasteCommand(id element) {
	return FSActionForElement(element) == @selector(paste:);
}

static BOOL FSElementIsInsertDrawingCommand(id element) {
	return FSActionForElement(element) == @selector(_insertDrawing:) && [FSTitleForElement(element) isEqualToString:@"Insert Drawing"];
}

static BOOL FSElementIsScanTextCommand(id element) {
	return FSActionForElement(element) == @selector(captureTextFromCamera:);
}

static BOOL FSElementTitleContainsWords(id element, NSArray<NSString *> *words) {
	NSString *title = FSNormalizedMenuTitle(FSTitleForElement(element));
	if(title.length == 0) {
		return NO;
	}
	for(NSString *word in words) {
		if([title rangeOfString:word options:NSCaseInsensitiveSearch].location == NSNotFound) {
			return NO;
		}
	}
	return YES;
}

static UICommand *FSSystemCommandWithImage(NSString *title, SEL action, NSString *symbolName) {
	UIImage *image = FSImageForMenuTitle(title);
	if(image == nil && symbolName.length > 0) {
		image = [UIImage systemImageNamed:symbolName];
	}
	return [UICommand commandWithTitle:title
	                             image:image
	                            action:action
	                      propertyList:nil];
}

static UICommand *FSReplacementPasteCommand(void) {
	UIImage *image = [UIImage systemImageNamed:@"doc.on.clipboard"];
	if(image == nil) {
		image = [UIImage systemImageNamed:@"doc.on.doc"];
	}
	return [UICommand commandWithTitle:@"Paste"
	                             image:image
	                            action:@selector(tmpTextMenuPlusSystemPaste:)
	                      propertyList:[FSPropertyListPrefix stringByAppendingString:@"system.paste"]];
}

static BOOL FSElementIsTextMenuPlusCommand(id element) {
	NSString *marker = FSMarkerFromSender(element);
	return [marker isKindOfClass:[NSString class]] && [marker hasPrefix:FSPropertyListPrefix];
}

static UICommand *FSCreateMenuCommand(NSString *title, SEL action, NSString *marker, NSString *symbolName) {
	UIImage *image = nil;
	if(symbolName.length > 0) {
		image = [UIImage systemImageNamed:symbolName];
	}
	return [UICommand commandWithTitle:title
	                             image:image
	                            action:action
	                      propertyList:[FSPropertyListPrefix stringByAppendingString:marker ?: title]];
}

static UIMenu *FSCreateInlineMenu(NSArray *children) {
	return [UIMenu menuWithTitle:@""
	                       image:nil
	                  identifier:nil
	                     options:UIMenuOptionsDisplayInline
	                    children:children];
}

static UIMenu *FSCreateTextCaseMenu(NSArray *children) {
	UIImage *image = [UIImage systemImageNamed:@"textformat"];
	if(image == nil) {
		image = [UIImage systemImageNamed:@"textformat.abc"];
	}
	return [UIMenu menuWithTitle:@"Text Case"
	                       image:image
	                  identifier:nil
	                     options:0
	                    children:children];
}

static NSArray *FSPrimaryInlineMenus(void) {
	NSArray *systemCommands = @[
		FSCreateMenuCommand(@"Undo", @selector(tmpTextMenuPlusSystemUndo:), @"system.undo", @"arrow.uturn.backward"),
		FSCreateMenuCommand(@"Redo", @selector(tmpTextMenuPlusSystemRedo:), @"system.redo", @"arrow.uturn.forward"),
		FSCreateMenuCommand(@"Select All", @selector(tmpTextMenuPlusSystemSelectAll:), @"system.selectAll", @"text.badge.checkmark")
	];
	NSArray *textCommands = @[
		FSCreateMenuCommand(@"Plain", @selector(tmpTextMenuPlusPlain:), @"plain", @"textformat"),
		FSCreateMenuCommand(@"Upper", @selector(tmpTextMenuPlusUppercase:), @"uppercase", @"textformat.size"),
		FSCreateMenuCommand(@"Lower", @selector(tmpTextMenuPlusLowercase:), @"lowercase", @"textformat.size.smaller"),
		FSCreateMenuCommand(@"Caps", @selector(tmpTextMenuPlusCapitalized:), @"capitalized", @"textformat.abc")
	];
	return @[FSCreateInlineMenu(systemCommands), FSCreateTextCaseMenu(textCommands)];
}

static NSString *FSMarkerFromSender(id sender) {
	if([sender respondsToSelector:@selector(propertyList)]) {
		id propertyList = [sender propertyList];
		if([propertyList isKindOfClass:[NSString class]]) {
			return propertyList;
		}
	}
	id associatedMarker = objc_getAssociatedObject(sender, &FSAssociatedMarkerKey);
	if([associatedMarker isKindOfClass:[NSString class]]) {
		return associatedMarker;
	}
	return nil;
}

static UIWindow *FSActiveWindow(void) {
	for(UIWindow *window in [[UIApplication sharedApplication] windows]) {
		if(window.isKeyWindow) {
			return window;
		}
	}
	return [[[UIApplication sharedApplication] windows] lastObject];
}

static void FSDismissPanel(void) {
	[FSPanelOverlay removeFromSuperview];
	FSPanelOverlay = nil;
}

static void FSRememberTextTarget(id target) {
	if(target != nil) {
		FSLastTextTarget = target;
	}
}

static void FSRequestAutoPanel(NSString *source) {
	(void)source;
	return;

	id target = FSLastTextTarget;
	if(target == nil || FSPanelOverlay != nil) {
		return;
	}

	NSTimeInterval now = [NSDate timeIntervalSinceReferenceDate];
	if(now - FSLastAutoPanelTime < 0.45) {
		return;
	}
	FSLastAutoPanelTime = now;

	dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.08 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
		id currentTarget = FSLastTextTarget;
				if(currentTarget != nil && FSPanelOverlay == nil && FSShouldRun()) {
			FSLog([NSString stringWithFormat:@"%@ auto-show vertical panel target=%@", source, NSStringFromClass([currentTarget class])]);
			FSShowPanelForTarget(currentTarget);
		}
	});
}

static UIButton *FSCreatePanelButton(NSString *title, SEL action, NSString *marker, id target) {
	UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem];
	button.translatesAutoresizingMaskIntoConstraints = NO;
	button.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.12];
	button.layer.cornerRadius = 8.0;
	button.layer.borderWidth = 1.0 / [UIScreen mainScreen].scale;
	button.layer.borderColor = [UIColor colorWithWhite:1.0 alpha:0.18].CGColor;
	button.contentEdgeInsets = UIEdgeInsetsMake(8, 8, 8, 8);
	button.contentHorizontalAlignment = UIControlContentHorizontalAlignmentLeft;
	button.titleLabel.font = [UIFont systemFontOfSize:13 weight:UIFontWeightSemibold];
	button.titleLabel.numberOfLines = 1;
	button.titleLabel.adjustsFontSizeToFitWidth = YES;
	button.titleLabel.minimumScaleFactor = 0.72;
	[button setTitle:title forState:UIControlStateNormal];
	[button setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
	[button addTarget:target action:action forControlEvents:UIControlEventTouchUpInside];
	if(marker.length > 0) {
		objc_setAssociatedObject(button, &FSAssociatedMarkerKey, [FSPropertyListPrefix stringByAppendingString:marker], OBJC_ASSOCIATION_COPY_NONATOMIC);
	}
	[button.heightAnchor constraintEqualToConstant:36.0].active = YES;
	return button;
}

static UILabel *FSCreatePanelHeader(NSString *title) {
	UILabel *label = [[UILabel alloc] init];
	label.translatesAutoresizingMaskIntoConstraints = NO;
	label.text = title;
	label.textColor = [UIColor colorWithWhite:1.0 alpha:0.72];
	label.font = [UIFont systemFontOfSize:12 weight:UIFontWeightBold];
	label.textAlignment = NSTextAlignmentLeft;
	return label;
}

static void FSAddPanelSection(UIStackView *content, NSString *title, NSArray<UIButton *> *buttons) {
	if(buttons.count == 0) {
		return;
	}

	[content addArrangedSubview:FSCreatePanelHeader(title)];
	for(UIButton *button in buttons) {
		[content addArrangedSubview:button];
	}
}

static void FSShowPanelForTarget(id target) {
	UIWindow *window = FSActiveWindow();
	if(window == nil) {
		return;
	}

	FSDismissPanel();

	UIView *overlay = [[UIView alloc] initWithFrame:window.bounds];
	overlay.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
	overlay.backgroundColor = [UIColor colorWithWhite:0.0 alpha:0.18];
	FSPanelOverlay = overlay;

	UIControl *dismissControl = [[UIControl alloc] initWithFrame:overlay.bounds];
	dismissControl.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
	[dismissControl addTarget:target action:@selector(tmpTextMenuPlusDismissPanel:) forControlEvents:UIControlEventTouchUpInside];
	[overlay addSubview:dismissControl];

	UIVisualEffectView *panel = [[UIVisualEffectView alloc] initWithEffect:[UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemMaterialDark]];
	panel.translatesAutoresizingMaskIntoConstraints = NO;
	panel.layer.cornerRadius = 14.0;
	panel.layer.masksToBounds = YES;
	[overlay addSubview:panel];

	UIScrollView *scrollView = [[UIScrollView alloc] init];
	scrollView.translatesAutoresizingMaskIntoConstraints = NO;
	scrollView.alwaysBounceVertical = YES;
	[panel.contentView addSubview:scrollView];

	UIStackView *content = [[UIStackView alloc] init];
	content.translatesAutoresizingMaskIntoConstraints = NO;
	content.axis = UILayoutConstraintAxisVertical;
	content.spacing = 6.0;
	content.layoutMargins = UIEdgeInsetsMake(10, 10, 10, 10);
	content.layoutMarginsRelativeArrangement = YES;
	[scrollView addSubview:content];

	NSArray *systemButtons = @[
		FSCreatePanelButton(@"Cut", @selector(tmpTextMenuPlusSystemCut:), nil, target),
		FSCreatePanelButton(@"Copy", @selector(tmpTextMenuPlusSystemCopy:), nil, target),
		FSCreatePanelButton(@"Paste", @selector(tmpTextMenuPlusSystemPaste:), nil, target),
		FSCreatePanelButton(@"Select All", @selector(tmpTextMenuPlusSystemSelectAll:), nil, target),
		FSCreatePanelButton(@"Undo", @selector(tmpTextMenuPlusSystemUndo:), nil, target),
		FSCreatePanelButton(@"Redo", @selector(tmpTextMenuPlusSystemRedo:), nil, target)
	];
	NSArray *textButtons = @[
		FSCreatePanelButton(@"Plain", @selector(tmpTextMenuPlusPlain:), @"plain", target),
		FSCreatePanelButton(@"Upper", @selector(tmpTextMenuPlusUppercase:), @"uppercase", target),
		FSCreatePanelButton(@"Lower", @selector(tmpTextMenuPlusLowercase:), @"lowercase", target),
		FSCreatePanelButton(@"Caps", @selector(tmpTextMenuPlusCapitalized:), @"capitalized", target)
	];
	FSAddPanelSection(content, @"System", systemButtons);
	FSAddPanelSection(content, @"Text", textButtons);

	CGFloat width = MIN(236.0, CGRectGetWidth(window.bounds) - 24.0);
	CGFloat height = MIN(392.0, CGRectGetHeight(window.bounds) - 150.0);
	[NSLayoutConstraint activateConstraints:@[
		[panel.centerXAnchor constraintEqualToAnchor:overlay.centerXAnchor],
		[panel.topAnchor constraintEqualToAnchor:overlay.safeAreaLayoutGuide.topAnchor constant:74.0],
		[panel.widthAnchor constraintEqualToConstant:width],
		[panel.heightAnchor constraintEqualToConstant:height],
		[scrollView.topAnchor constraintEqualToAnchor:panel.contentView.topAnchor],
		[scrollView.leadingAnchor constraintEqualToAnchor:panel.contentView.leadingAnchor],
		[scrollView.trailingAnchor constraintEqualToAnchor:panel.contentView.trailingAnchor],
		[scrollView.bottomAnchor constraintEqualToAnchor:panel.contentView.bottomAnchor],
		[content.topAnchor constraintEqualToAnchor:scrollView.contentLayoutGuide.topAnchor],
		[content.leadingAnchor constraintEqualToAnchor:scrollView.contentLayoutGuide.leadingAnchor],
		[content.trailingAnchor constraintEqualToAnchor:scrollView.contentLayoutGuide.trailingAnchor],
		[content.bottomAnchor constraintEqualToAnchor:scrollView.contentLayoutGuide.bottomAnchor],
		[content.widthAnchor constraintEqualToAnchor:scrollView.frameLayoutGuide.widthAnchor]
	]];

	[window addSubview:overlay];
}

static NSString *FSStyleNameFromSender(id sender) {
	NSString *propertyList = FSMarkerFromSender(sender);
	if(![propertyList isKindOfClass:[NSString class]] ||
	   ![propertyList hasPrefix:FSPropertyListPrefix]) {
		return nil;
	}

	NSString *marker = [propertyList substringFromIndex:FSPropertyListPrefix.length];
	NSString *stylePrefix = @"style.";
	if(![marker hasPrefix:stylePrefix]) {
		return nil;
	}
	return [marker substringFromIndex:stylePrefix.length];
}

static NSString *FSCombineStyleNameFromSender(id sender) {
	NSString *propertyList = FSMarkerFromSender(sender);
	if(![propertyList isKindOfClass:[NSString class]] ||
	   ![propertyList hasPrefix:FSPropertyListPrefix]) {
		return nil;
	}

	NSString *marker = [propertyList substringFromIndex:FSPropertyListPrefix.length];
	NSString *combinePrefix = @"combine.";
	if(![marker hasPrefix:combinePrefix]) {
		return nil;
	}
	return [marker substringFromIndex:combinePrefix.length];
}

static NSArray *FSChildrenByAddingProbe(NSArray *children, BOOL *changed) {
	if(![children isKindOfClass:[NSArray class]]) {
		return children;
	}

	BOOL alreadyHasTextMenuPlusCommands = NO;
	for(id child in children) {
		if(FSElementIsTextMenuPlusCommand(child)) {
			alreadyHasTextMenuPlusCommands = YES;
			break;
		}
		if([child isKindOfClass:[UIMenu class]]) {
			for(id nestedChild in [(UIMenu *)child children]) {
				if(FSElementIsTextMenuPlusCommand(nestedChild)) {
					alreadyHasTextMenuPlusCommands = YES;
					break;
				}
			}
			if(alreadyHasTextMenuPlusCommands) {
				break;
			}
		}
	}

	NSMutableArray *priorityChildren = [NSMutableArray array];
	NSMutableArray *updatedChildren = [NSMutableArray arrayWithCapacity:children.count + 2];
	for(id child in children) {
		id updatedChild = child;
		if([updatedChild isKindOfClass:[UIMenu class]]) {
			BOOL nestedChanged = NO;
			NSArray *nestedChildren = FSChildrenByAddingProbe([(UIMenu *)updatedChild children], &nestedChanged);
			if(nestedChanged) {
				updatedChild = [(UIMenu *)updatedChild menuByReplacingChildren:nestedChildren];
				if(changed != NULL) {
					*changed = YES;
				}
			}
		}

		if(FSElementIsCopyCommand(updatedChild)) {
			FSRequestAutoPanel(@"FSChildrenByAddingProbe");
		}

		BOOL wasPasteCommand = FSElementIsPasteCommand(updatedChild);
		if(wasPasteCommand) {
			updatedChild = FSReplacementPasteCommand();
			if(changed != NULL) {
				*changed = YES;
			}
		} else if(FSElementIsInsertDrawingCommand(updatedChild)) {
			updatedChild = FSSystemCommandWithImage(@"Insert Drawing", @selector(_insertDrawing:), @"pencil.tip.crop.circle");
			if(changed != NULL) {
				*changed = YES;
			}
		} else if(FSElementIsScanTextCommand(updatedChild)) {
			updatedChild = FSSystemCommandWithImage(@"Scan Text", @selector(captureTextFromCamera:), @"text.viewfinder");
			if(changed != NULL) {
				*changed = YES;
			}
		} else if(FSElementTitleContainsWords(updatedChild, @[@"Paste", @"Search"])) {
			updatedChild = FSSystemCommandWithImage(FSTitleForElement(updatedChild), FSActionForElement(updatedChild), @"magnifyingglass");
			if(changed != NULL) {
				*changed = YES;
			}
		}

		if(FSElementTitleContainsWords(updatedChild, @[@"Paste", @"Go"])) {
			[priorityChildren addObject:updatedChild];
			if(changed != NULL) {
				*changed = YES;
			}
		} else {
			[updatedChildren addObject:updatedChild];
		}
		if(wasPasteCommand && !alreadyHasTextMenuPlusCommands) {
			[updatedChildren addObjectsFromArray:FSPrimaryInlineMenus()];
			if(changed != NULL) {
				*changed = YES;
			}
		}
	}

	if(priorityChildren.count > 0) {
		[priorityChildren addObjectsFromArray:updatedChildren];
		return priorityChildren;
	}
	return updatedChildren;
}

static NSArray *FSElementsByAddingProbe(NSArray *elements, NSString *source) {
	(void)source;
	if(!FSShouldRun() || ![elements isKindOfClass:[NSArray class]]) {
		return elements;
	}
	BOOL changed = NO;
	NSArray *updated = FSChildrenByAddingProbe(elements, &changed);
	return updated;
}

static UIMenu *FSMenuByAddingProbe(UIMenu *menu, NSString *source) {
	(void)source;
	if(!FSShouldRun() || ![menu isKindOfClass:[UIMenu class]]) {
		return menu;
	}
	BOOL changed = NO;
	NSArray *updatedChildren = FSChildrenByAddingProbe(menu.children, &changed);
	if(!changed) {
		return menu;
	}
	return [menu menuByReplacingChildren:updatedChildren];
}

static BOOL FSCanEditText(id target) {
	if(![target respondsToSelector:@selector(selectedTextRange)] ||
	   ![target respondsToSelector:@selector(textInRange:)] ||
	   ![target respondsToSelector:@selector(replaceRange:withText:)]) {
		return NO;
	}
	if([target respondsToSelector:@selector(isEditable)] && ![(id)target isEditable]) {
		return NO;
	}
	if([target respondsToSelector:@selector(isEnabled)] && ![(id)target isEnabled]) {
		return NO;
	}
	if([target respondsToSelector:@selector(isSelectable)] && ![target respondsToSelector:@selector(isEditable)]) {
		return NO;
	}
	return YES;
}

static BOOL FSCanTransformText(id target) {
	if(!FSCanEditText(target)) {
		return NO;
	}
	UITextRange *range = [(id<UITextInput>)target selectedTextRange];
	NSString *selectedText = [(id<UITextInput>)target textInRange:range];
	return selectedText.length > 0;
}

static NSUndoManager *FSUndoManagerForTarget(id target) {
	if(![target respondsToSelector:@selector(undoManager)]) {
		return nil;
	}
	NSUndoManager *undoManager = [target undoManager];
	return [undoManager isKindOfClass:[NSUndoManager class]] ? undoManager : nil;
}

static BOOL FSReplaceSelectedTextViaTextStorage(id target, NSString *replacement) {
	if(![target respondsToSelector:@selector(selectedRange)] ||
	   ![target respondsToSelector:@selector(setSelectedRange:)] ||
	   ![target respondsToSelector:@selector(textStorage)]) {
		return NO;
	}

	NSTextStorage *textStorage = [target textStorage];
	if(![textStorage isKindOfClass:[NSTextStorage class]]) {
		return NO;
	}

	NSRange selectedRange = [target selectedRange];
	if(selectedRange.location == NSNotFound || NSMaxRange(selectedRange) > textStorage.length) {
		return NO;
	}

	NSAttributedString *attributedReplacement = [[NSAttributedString alloc] initWithString:replacement ?: @""];
	[textStorage beginEditing];
	[textStorage replaceCharactersInRange:selectedRange withAttributedString:attributedReplacement];
	[textStorage endEditing];
	[target setSelectedRange:NSMakeRange(selectedRange.location, replacement.length)];
	return YES;
}

static void FSReplaceSelectedText(id target, NSString *(^transform)(NSString *text), NSString *actionName, id sender) {
	if(!FSCanTransformText(target)) {
		FSLog([NSString stringWithFormat:@"%@ unsupported or empty target=%@", actionName, NSStringFromClass([target class])]);
		return;
	}

	id<UITextInput> textInput = (id<UITextInput>)target;
	UITextRange *range = [textInput selectedTextRange];
	NSString *selectedText = [textInput textInRange:range];
	NSString *replacement = transform(selectedText);
	BOOL replacedViaTextStorage = FSReplaceSelectedTextViaTextStorage(target, replacement);
	if(!replacedViaTextStorage) {
		[textInput replaceRange:range withText:replacement];
	}
	FSDismissPanel();
	FSLog([NSString stringWithFormat:@"%@ replaced %lu chars target=%@ sender=%@",
		actionName,
		(unsigned long)selectedText.length,
		NSStringFromClass([target class]),
		NSStringFromClass([sender class])]);
}

static void FSPerformSystemAction(id target, SEL action, id sender, NSString *actionName) {
	BOOL sent = [[UIApplication sharedApplication] sendAction:action to:target from:sender forEvent:nil];
	FSDismissPanel();
	FSLog([NSString stringWithFormat:@"%@ sent=%d target=%@", actionName, sent, NSStringFromClass([target class])]);
}

static NSArray *FSStyleDefinitions(void) {
	static NSArray *styleDefinitions = nil;
	static dispatch_once_t onceToken;
	dispatch_once(&onceToken, ^{
		styleDefinitions = [NSArray arrayWithContentsOfFile:FSStylesPath] ?: @[];
		FSLog([NSString stringWithFormat:@"loaded %lu style definitions", (unsigned long)styleDefinitions.count]);
	});
	return styleDefinitions;
}

static NSDictionary *FSStyleDefinition(NSString *name) {
	if(name.length == 0) {
		return nil;
	}
	for(NSDictionary *style in FSStyleDefinitions()) {
		if(![style isKindOfClass:[NSDictionary class]]) {
			continue;
		}
		if([[style objectForKey:@"name"] isEqualToString:name]) {
			return style;
		}
	}
	return nil;
}

static NSDictionary *FSStyleMap(NSString *name) {
	NSDictionary *style = FSStyleDefinition(name);
	NSDictionary *map = [style objectForKey:@"map"];
	if([map isKindOfClass:[NSDictionary class]]) {
		return map;
	}
	return nil;
}

static BOOL FSPlainCandidateShouldReplace(NSString *existingPlain, NSString *newPlain) {
	if(existingPlain.length == 0 || newPlain.length == 0) {
		return existingPlain.length == 0 && newPlain.length > 0;
	}
	if([newPlain isEqualToString:[newPlain lowercaseString]] &&
	   ![existingPlain isEqualToString:[existingPlain lowercaseString]]) {
		return YES;
	}
	if([newPlain isEqualToString:[newPlain lowercaseString]] == [existingPlain isEqualToString:[existingPlain lowercaseString]] &&
	   [newPlain compare:existingPlain] == NSOrderedAscending) {
		return YES;
	}
	return NO;
}

static NSDictionary *FSReverseStyleInfoMap(void) {
	static NSDictionary *reverseMap = nil;
	static dispatch_once_t onceToken;
	dispatch_once(&onceToken, ^{
		NSMutableDictionary *map = [NSMutableDictionary dictionary];
		for(NSDictionary *style in FSStyleDefinitions()) {
			if(![style isKindOfClass:[NSDictionary class]]) {
				continue;
			}
			NSString *name = [style objectForKey:@"name"];
			NSDictionary *styleMap = [style objectForKey:@"map"];
			if(![name isKindOfClass:[NSString class]] ||
			   ![styleMap isKindOfClass:[NSDictionary class]]) {
				continue;
			}
			for(NSString *plain in styleMap) {
				NSString *styled = [styleMap objectForKey:plain];
				if([plain isKindOfClass:[NSString class]] &&
				   [styled isKindOfClass:[NSString class]] &&
				   styled.length > 0 &&
				   ![styled isEqualToString:plain]) {
					NSDictionary *existingInfo = [map objectForKey:styled];
					NSString *existingPlain = [existingInfo objectForKey:@"plain"];
					if(existingInfo == nil || FSPlainCandidateShouldReplace(existingPlain, plain)) {
						[map setObject:@{@"plain": plain, @"name": name} forKey:styled];
					}
				}
			}
		}
		reverseMap = [map copy];
		FSLog([NSString stringWithFormat:@"built reverse style info map with %lu entries", (unsigned long)reverseMap.count]);
	});
	return reverseMap;
}

static NSString *FSCombineString(NSString *name) {
	NSDictionary *style = FSStyleDefinition(name);
	NSString *combine = [style objectForKey:@"combine"];
	if([combine isKindOfClass:[NSString class]]) {
		return combine;
	}
	return nil;
}

static NSArray *TMPTextMenuPlusCombineMarks(void) {
	static NSArray *combineMarks = nil;
	static dispatch_once_t onceToken;
	dispatch_once(&onceToken, ^{
		NSMutableOrderedSet *marks = [NSMutableOrderedSet orderedSet];
		for(NSDictionary *style in FSStyleDefinitions()) {
			if(![style isKindOfClass:[NSDictionary class]]) {
				continue;
			}
			NSString *combine = [style objectForKey:@"combine"];
			if(![combine isKindOfClass:[NSString class]] || combine.length == 0) {
				continue;
			}
			[combine enumerateSubstringsInRange:NSMakeRange(0, combine.length)
			                            options:NSStringEnumerationByComposedCharacterSequences
			                         usingBlock:^(NSString *substring, NSRange substringRange, NSRange enclosingRange, BOOL *stop) {
				if(substring.length > 0) {
					[marks addObject:substring];
				}
			}];
		}
		combineMarks = [[marks array] copy];
		FSLog([NSString stringWithFormat:@"loaded %lu TextMenuPlus combine marks", (unsigned long)combineMarks.count]);
	});
	return combineMarks;
}

static NSString *FSStyleNameFromText(NSString *text) {
	NSString *withoutCombine = FSStripTextMenuPlusCombineMarks(text);
	NSDictionary *reverseMap = FSReverseStyleInfoMap();
	NSMutableDictionary *counts = [NSMutableDictionary dictionary];
	__block NSUInteger styledCount = 0;
	__block NSUInteger letterCount = 0;
	[withoutCombine enumerateSubstringsInRange:NSMakeRange(0, withoutCombine.length)
	                                   options:NSStringEnumerationByComposedCharacterSequences
	                                usingBlock:^(NSString *substring, NSRange substringRange, NSRange enclosingRange, BOOL *stop) {
		if([substring rangeOfCharacterFromSet:[NSCharacterSet letterCharacterSet]].location != NSNotFound) {
			letterCount++;
		}
		NSDictionary *info = [reverseMap objectForKey:substring];
		NSString *name = [info objectForKey:@"name"];
		if([name isKindOfClass:[NSString class]] && name.length > 0) {
			styledCount++;
			NSNumber *count = [counts objectForKey:name] ?: @0;
			[counts setObject:@(count.unsignedIntegerValue + 1) forKey:name];
		}
	}];

	if(styledCount < 2 || counts.count == 0) {
		return nil;
	}
	if(letterCount > 0 && styledCount * 2 < letterCount) {
		return nil;
	}

	__block NSString *dominantName = nil;
	__block NSUInteger dominantCount = 0;
	[counts enumerateKeysAndObjectsUsingBlock:^(NSString *name, NSNumber *count, BOOL *stop) {
		if(count.unsignedIntegerValue > dominantCount) {
			dominantName = name;
			dominantCount = count.unsignedIntegerValue;
		}
	}];

	if(dominantCount * 2 < styledCount) {
		return nil;
	}

	return dominantName;
}

static NSString *FSCombineStyleNameFromText(NSString *text) {
	for(NSDictionary *style in FSStyleDefinitions()) {
		if(![style isKindOfClass:[NSDictionary class]]) {
			continue;
		}
		NSString *name = [style objectForKey:@"name"];
		NSString *combine = [style objectForKey:@"combine"];
		if(![name isKindOfClass:[NSString class]] ||
		   ![combine isKindOfClass:[NSString class]] ||
		   combine.length == 0) {
			continue;
		}
		if([text rangeOfString:combine].location != NSNotFound) {
			return name;
		}
	}
	return nil;
}

static NSString *FSApplyStyleName(NSString *text, NSString *styleName);

static NSDictionary *FSReverseStyleMap(void) {
	static NSDictionary *reverseMap = nil;
	static dispatch_once_t onceToken;
	dispatch_once(&onceToken, ^{
		NSMutableDictionary *map = [NSMutableDictionary dictionary];
		NSDictionary *infoMap = FSReverseStyleInfoMap();
		for(NSString *styled in infoMap) {
			NSDictionary *info = [infoMap objectForKey:styled];
			NSString *plain = [info objectForKey:@"plain"];
			if([plain isKindOfClass:[NSString class]]) {
				[map setObject:plain forKey:styled];
			}
		}
		reverseMap = [map copy];
		FSLog([NSString stringWithFormat:@"built reverse style map with %lu entries", (unsigned long)reverseMap.count]);
	});
	return reverseMap;
}

static NSString *FSPlainTextFromStyledText(NSString *text) {
	if(text.length == 0) {
		return text;
	}

	NSDictionary *reverseMap = FSReverseStyleMap();
	if(reverseMap.count == 0) {
		return text;
	}

	NSMutableString *result = [NSMutableString string];
	[text enumerateSubstringsInRange:NSMakeRange(0, text.length)
	                         options:NSStringEnumerationByComposedCharacterSequences
	                      usingBlock:^(NSString *substring, NSRange substringRange, NSRange enclosingRange, BOOL *stop) {
		NSString *plain = [reverseMap objectForKey:substring];
		[result appendString:plain ?: substring];
	}];
	return result;
}

static NSString *FSStripTextMenuPlusCombineMarks(NSString *text) {
	if(text.length == 0) {
		return text;
	}

	NSArray *marks = TMPTextMenuPlusCombineMarks();
	if(marks.count == 0) {
		return text;
	}

	NSMutableString *result = [text mutableCopy];
	for(NSString *mark in marks) {
		if(mark.length == 0) {
			continue;
		}
		[result replaceOccurrencesOfString:mark
		                           withString:@""
		                              options:0
		                                range:NSMakeRange(0, result.length)];
	}
	return result;
}

static NSString *FSPlainTextForTransform(NSString *text) {
	return FSPlainTextFromStyledText(FSStripTextMenuPlusCombineMarks(text));
}

static NSString *FSApplyStyleMap(NSString *text, NSDictionary *map) {
	if(text.length == 0 || map.count == 0) {
		return text;
	}

	NSMutableString *result = [NSMutableString string];
	[text enumerateSubstringsInRange:NSMakeRange(0, text.length)
	                         options:NSStringEnumerationByComposedCharacterSequences
	                      usingBlock:^(NSString *substring, NSRange substringRange, NSRange enclosingRange, BOOL *stop) {
		NSString *replacement = [map objectForKey:substring];
		[result appendString:replacement ?: substring];
	}];
	return result;
}

static NSString *FSApplyStyleName(NSString *text, NSString *styleName) {
	NSDictionary *map = FSStyleMap(styleName);
	if(map.count == 0) {
		return text;
	}
	return FSApplyStyleMap(text, map);
}

static NSString *FSApplyCombineStyle(NSString *text, NSString *combine) {
	if(text.length == 0 || combine.length == 0) {
		return text;
	}

	NSMutableString *result = [NSMutableString string];
	NSCharacterSet *whitespace = [NSCharacterSet whitespaceAndNewlineCharacterSet];
	[text enumerateSubstringsInRange:NSMakeRange(0, text.length)
	                         options:NSStringEnumerationByComposedCharacterSequences
	                      usingBlock:^(NSString *substring, NSRange substringRange, NSRange enclosingRange, BOOL *stop) {
		if([[substring stringByTrimmingCharactersInSet:whitespace] length] == 0) {
			[result appendString:substring];
		} else {
			[result appendString:substring];
			[result appendString:combine];
		}
	}];
	return result;
}

static NSString *FSRenderTextWithState(NSString *plainText, NSString *styleName, NSString *combineName) {
	NSString *result = FSApplyStyleName(plainText, styleName);
	NSString *combine = FSCombineString(combineName);
	if(combine.length > 0) {
		result = FSApplyCombineStyle(result, combine);
	}
	return result;
}

static NSString *FSApplyTextTransformPreservingState(NSString *text, NSString *(^transform)(NSString *plainText)) {
	NSString *styleName = FSStyleNameFromText(text);
	NSString *combineName = FSCombineStyleNameFromText(text);
	NSString *plainText = FSPlainTextForTransform(text);
	return FSRenderTextWithState(transform(plainText), styleName, combineName);
}

static void FSReplaceSelectedTextWithStyle(id target, NSString *styleName, NSString *actionName, id sender) {
	if(FSStyleMap(styleName).count == 0) {
		FSLog([NSString stringWithFormat:@"%@ missing style map %@", actionName, styleName]);
		return;
	}

	FSReplaceSelectedText(target, ^NSString *(NSString *text) {
		NSString *combineName = FSCombineStyleNameFromText(text);
		NSString *plainText = FSPlainTextForTransform(text);
		return FSRenderTextWithState(plainText, styleName, combineName);
	}, actionName, sender);
}

static void FSReplaceSelectedTextWithCombineStyle(id target, NSString *styleName, NSString *actionName, id sender) {
	NSString *combine = FSCombineString(styleName);
	if(combine.length == 0) {
		FSLog([NSString stringWithFormat:@"%@ missing combine style %@", actionName, styleName]);
		return;
	}

	FSReplaceSelectedText(target, ^NSString *(NSString *text) {
		NSString *currentStyleName = FSStyleNameFromText(text);
		NSString *plainText = FSPlainTextForTransform(text);
		return FSRenderTextWithState(plainText, currentStyleName, styleName);
	}, actionName, sender);
}

static NSString *FSSpongebobText(NSString *text) {
	NSString *plainText = FSPlainTextForTransform(text);
	NSMutableString *result = [NSMutableString string];
	__block BOOL uppercase = NO;
	[plainText enumerateSubstringsInRange:NSMakeRange(0, plainText.length)
	                              options:NSStringEnumerationByComposedCharacterSequences
	                           usingBlock:^(NSString *substring, NSRange substringRange, NSRange enclosingRange, BOOL *stop) {
		NSString *lower = [substring lowercaseString];
		NSString *upper = [substring uppercaseString];
		if([lower isEqualToString:upper]) {
			[result appendString:substring];
			return;
		}
		[result appendString:(uppercase ? upper : lower)];
		uppercase = !uppercase;
	}];
	return result;
}

%hook _UIEditMenuProvider

+ (id)menuElementsFromResponderChain:(id)responderChain atLocation:(CGPoint)location inCoordinateSpace:(id)coordinateSpace includeMenuControllerItems:(BOOL)includeMenuControllerItems {
	id result = %orig(responderChain, location, coordinateSpace, includeMenuControllerItems);
	if(!FSShouldRun()) {
		return result;
	}
	return FSElementsByAddingProbe(result, @"_UIEditMenuProvider");
}

%end

%hook _UIContextMenuInteractionBasedTextContextInteraction

- (id)_editMenuForSuggestedActions:(id)suggestedActions rvItem:(id)rvItem isEditMenu:(BOOL)isEditMenu {
	id result = %orig(suggestedActions, rvItem, isEditMenu);
	if(!FSShouldRun()) {
		return result;
	}
	if([result isKindOfClass:[UIMenu class]]) {
		return FSMenuByAddingProbe(result, @"_editMenuForSuggestedActions");
	}
	return result;
}

%end

%hook _UIEditMenuListView

- (id)initWithMenu:(id)menu titleView:(id)titleView {
	id result = %orig(menu, titleView);
	if(!FSShouldRun()) {
		return result;
	}
	FSForceVerticalAxis(result, @"_UIEditMenuListView initWithMenu");
	return result;
}

- (void)reloadWithMenu:(id)menu titleView:(id)titleView animated:(BOOL)animated {
	%orig(menu, titleView, animated);
	if(!FSShouldRun()) {
		return;
	}
	FSForceVerticalAxis((id)self, @"_UIEditMenuListView reloadWithMenu");
}

- (void)layoutSubviews {
	if(FSShouldRun()) {
		FSForceVerticalAxis((id)self, @"_UIEditMenuListView layoutSubviews");
	}
	%orig;
	if(!FSShouldRun()) {
		return;
	}
	FSStyleVisibleMenuCells((UIView *)self);
	dispatch_async(dispatch_get_main_queue(), ^{
		FSStyleVisibleMenuCells((UIView *)self);
	});
}

- (CGSize)_verticalMenuContentSizeFittingContainer:(id)container containerSize:(CGSize)containerSize traits:(id)traits {
	CGSize size = %orig(container, containerSize, traits);
	if(!FSShouldRun()) {
		return size;
	}
	size.width = MIN(size.width, 210.0);
	size.height = MIN(size.height, FSMaxMenuHeight(containerSize));
	return size;
}

- (CGSize)intrinsicContentSizeForContainer:(id)container containerSize:(CGSize)containerSize {
	CGSize size = %orig(container, containerSize);
	if(!FSShouldRun()) {
		return size;
	}
	size.width = MIN(size.width, 210.0);
	size.height = MIN(size.height, FSMaxMenuHeight(containerSize));
	return size;
}

- (void)collectionView:(id)collectionView willDisplayCell:(id)cell forItemAtIndexPath:(id)indexPath {
	%orig(collectionView, cell, indexPath);
	if(!FSShouldRun()) {
		return;
	}
	if([cell isKindOfClass:[UICollectionViewCell class]]) {
		FSStyleMenuCell((UICollectionViewCell *)cell);
	}
}

%end

%hook _UIEditMenuListViewCell

- (void)layoutSubviews {
	%orig;
	if(!FSShouldRun()) {
		return;
	}
	FSStyleMenuCell((UICollectionViewCell *)self);
	dispatch_async(dispatch_get_main_queue(), ^{
		FSStyleMenuCell((UICollectionViewCell *)self);
	});
}

%end

%hook _UIEditMenuInteractionMenuController

- (void)_presentEditMenu {
	if(!FSShouldRun()) {
		%orig;
		return;
	}
	%orig;
}

- (void)showMenuFromView:(id)view rect:(CGRect)rect {
	if(!FSShouldRun()) {
		%orig(view, rect);
		return;
	}
	%orig(view, rect);
}

%end

%hook _UIEditMenuPresentation

- (NSInteger)_listViewAxisForTraitCollection:(id)traitCollection {
	NSInteger originalAxis = %orig(traitCollection);
	if(!FSShouldRun()) {
		return originalAxis;
	}
	return 1;
}

- (void)_displayMenu:(id)menu reason:(NSInteger)reason {
	if(!FSShouldRun()) {
		%orig(menu, reason);
		return;
	}
	%orig(menu, reason);
}

%end

%hook UIResponder

- (BOOL)canPerformAction:(SEL)action withSender:(id)sender {
	if(!FSShouldRun()) {
		return %orig(action, sender);
	}
	if(FSCanTransformText(self)) {
		FSRememberTextTarget(self);
	}
	if(action == @selector(tmpTextMenuPlusSystemPaste:)) {
		return %orig(@selector(paste:), sender);
	}
	if(action == @selector(tmpTextMenuPlusSystemUndo:)) {
		return FSCanEditText(self);
	}
	if(action == @selector(tmpTextMenuPlusSystemRedo:)) {
		return FSCanEditText(self);
	}
	if(action == @selector(tmpTextMenuPlusShowPanel:) ||
	   action == @selector(tmpTextMenuPlusSystemCut:) ||
	   action == @selector(tmpTextMenuPlusSystemCopy:) ||
	   action == @selector(tmpTextMenuPlusSystemSelectAll:) ||
	   action == @selector(tmpTextMenuPlusPlain:) ||
	   action == @selector(tmpTextMenuPlusUppercase:) ||
	   action == @selector(tmpTextMenuPlusLowercase:) ||
	   action == @selector(tmpTextMenuPlusCapitalized:) ||
	   action == @selector(tmpTextMenuPlusBoldStyle:) ||
	   action == @selector(tmpTextMenuPlusItalicStyle:) ||
	   action == @selector(tmpTextMenuPlusMonoStyle:)) {
		return FSCanTransformText(self);
	}
	if(action == @selector(tmpTextMenuPlusApplyStyle:) ||
	   action == @selector(tmpTextMenuPlusApplyCombineStyle:) ||
	   action == @selector(tmpTextMenuPlusSpongebob:)) {
		return FSCanTransformText(self);
	}
	return %orig(action, sender);
}

%new
- (void)tmpTextMenuPlusShowPanel:(id)sender {
	FSShowPanelForTarget(self);
}

%new
- (void)tmpTextMenuPlusDismissPanel:(id)sender {
	FSDismissPanel();
}

%new
- (void)tmpTextMenuPlusSystemCut:(id)sender {
	FSPerformSystemAction(self, @selector(cut:), sender, @"tmpTextMenuPlusSystemCut");
}

%new
- (void)tmpTextMenuPlusSystemCopy:(id)sender {
	FSPerformSystemAction(self, @selector(copy:), sender, @"tmpTextMenuPlusSystemCopy");
}

%new
- (void)tmpTextMenuPlusSystemPaste:(id)sender {
	FSPerformSystemAction(self, @selector(paste:), sender, @"tmpTextMenuPlusSystemPaste");
}

%new
- (void)tmpTextMenuPlusSystemSelectAll:(id)sender {
	FSPerformSystemAction(self, @selector(selectAll:), sender, @"tmpTextMenuPlusSystemSelectAll");
}

%new
- (void)tmpTextMenuPlusSystemUndo:(id)sender {
	NSUndoManager *undoManager = FSUndoManagerForTarget(self);
	if(![undoManager canUndo]) {
		FSLog(@"tmpTextMenuPlusSystemUndo undoManager cannot undo");
		return;
	}
	[undoManager undo];
}

%new
- (void)tmpTextMenuPlusSystemRedo:(id)sender {
	NSUndoManager *undoManager = FSUndoManagerForTarget(self);
	if(![undoManager canRedo]) {
		FSLog(@"tmpTextMenuPlusSystemRedo undoManager cannot redo");
		return;
	}
	[undoManager redo];
}

%new
- (void)tmpTextMenuPlusPlain:(id)sender {
	FSReplaceSelectedText(self, ^NSString *(NSString *text) {
		return FSPlainTextForTransform(text);
	}, @"tmpTextMenuPlusPlain", sender);
}

%new
- (void)tmpTextMenuPlusUppercase:(id)sender {
	FSReplaceSelectedText(self, ^NSString *(NSString *text) {
		return FSApplyTextTransformPreservingState(text, ^NSString *(NSString *plainText) {
			return [plainText uppercaseString];
		});
	}, @"tmpTextMenuPlusUppercase", sender);
}

%new
- (void)tmpTextMenuPlusLowercase:(id)sender {
	FSReplaceSelectedText(self, ^NSString *(NSString *text) {
		return FSApplyTextTransformPreservingState(text, ^NSString *(NSString *plainText) {
			return [plainText lowercaseString];
		});
	}, @"tmpTextMenuPlusLowercase", sender);
}

%new
- (void)tmpTextMenuPlusCapitalized:(id)sender {
	FSReplaceSelectedText(self, ^NSString *(NSString *text) {
		return FSApplyTextTransformPreservingState(text, ^NSString *(NSString *plainText) {
			return [plainText capitalizedString];
		});
	}, @"tmpTextMenuPlusCapitalized", sender);
}

%new
- (void)tmpTextMenuPlusBoldStyle:(id)sender {
	FSReplaceSelectedTextWithStyle(self, @"bold", @"tmpTextMenuPlusBoldStyle", sender);
}

%new
- (void)tmpTextMenuPlusItalicStyle:(id)sender {
	FSReplaceSelectedTextWithStyle(self, @"italic", @"tmpTextMenuPlusItalicStyle", sender);
}

%new
- (void)tmpTextMenuPlusMonoStyle:(id)sender {
	FSReplaceSelectedTextWithStyle(self, @"mono", @"tmpTextMenuPlusMonoStyle", sender);
}

%new
- (void)tmpTextMenuPlusApplyStyle:(id)sender {
	NSString *styleName = FSStyleNameFromSender(sender);
	if(styleName.length == 0) {
		FSLog([NSString stringWithFormat:@"tmpTextMenuPlusApplyStyle missing style sender=%@", NSStringFromClass([sender class])]);
		return;
	}
	FSReplaceSelectedTextWithStyle(self, styleName, [@"tmpTextMenuPlusApplyStyle:" stringByAppendingString:styleName], sender);
}

%new
- (void)tmpTextMenuPlusApplyCombineStyle:(id)sender {
	NSString *styleName = FSCombineStyleNameFromSender(sender);
	if(styleName.length == 0) {
		FSLog([NSString stringWithFormat:@"tmpTextMenuPlusApplyCombineStyle missing style sender=%@", NSStringFromClass([sender class])]);
		return;
	}
	FSReplaceSelectedTextWithCombineStyle(self, styleName, [@"tmpTextMenuPlusApplyCombineStyle:" stringByAppendingString:styleName], sender);
}

%new
- (void)tmpTextMenuPlusSpongebob:(id)sender {
	FSReplaceSelectedText(self, ^NSString *(NSString *text) {
		return FSApplyTextTransformPreservingState(text, ^NSString *(NSString *plainText) {
			return FSSpongebobText(plainText);
		});
	}, @"tmpTextMenuPlusSpongebob", sender);
}

%end
