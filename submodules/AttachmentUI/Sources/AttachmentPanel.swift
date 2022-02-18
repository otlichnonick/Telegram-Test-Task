import Foundation
import UIKit
import AsyncDisplayKit
import Display
import ComponentFlow
import Postbox
import TelegramCore
import TelegramPresentationData
import AccountContext
import AttachmentTextInputPanelNode
import ChatPresentationInterfaceState
import ChatSendMessageActionUI
import ChatTextLinkEditUI

private let buttonSize = CGSize(width: 75.0, height: 49.0)
private let iconSize = CGSize(width: 30.0, height: 30.0)
private let sideInset: CGFloat = 0.0

private enum AttachmentButtonTransition {
    case transitionIn
    case selection
}


private final class AttachButtonComponent: CombinedComponent {
    let context: AccountContext
    let type: AttachmentButtonType
    let isSelected: Bool
    let isCollapsed: Bool
    let transitionFraction: CGFloat
    let strings: PresentationStrings
    let theme: PresentationTheme
    let action: () -> Void
    
    init(
        context: AccountContext,
        type: AttachmentButtonType,
        isSelected: Bool,
        isCollapsed: Bool,
        transitionFraction: CGFloat,
        strings: PresentationStrings,
        theme: PresentationTheme,
        action: @escaping () -> Void
    ) {
        self.context = context
        self.type = type
        self.isSelected = isSelected
        self.isCollapsed = isCollapsed
        self.transitionFraction = transitionFraction
        self.strings = strings
        self.theme = theme
        self.action = action
    }

    static func ==(lhs: AttachButtonComponent, rhs: AttachButtonComponent) -> Bool {
        if lhs.context !== rhs.context {
            return false
        }
        if lhs.type != rhs.type {
            return false
        }
        if lhs.isSelected != rhs.isSelected {
            return false
        }
        if lhs.isCollapsed != rhs.isCollapsed {
            return false
        }
        if lhs.transitionFraction != rhs.transitionFraction {
            return false
        }
        if lhs.strings !== rhs.strings {
            return false
        }
        if lhs.theme !== rhs.theme {
            return false
        }
        return true
    }
    
    static var body: Body {
        let icon = Child(Image.self)
        let title = Child(Text.self)

        return { context in
            let name: String
            let animationName: String?
            let imageName: String?
            
            let component = context.component
            let strings = component.strings
            
            switch component.type {
            case .camera:
                name = strings.Attachment_Camera
                animationName = "anim_camera"
                imageName = "Chat/Attach Menu/Camera"
            case .gallery:
                name = strings.Attachment_Gallery
                animationName = "anim_gallery"
                imageName = "Chat/Attach Menu/Gallery"
            case .file:
                name = strings.Attachment_File
                animationName = "anim_file"
                imageName = "Chat/Attach Menu/File"
            case .location:
                name = strings.Attachment_Location
                animationName = "anim_location"
                imageName = "Chat/Attach Menu/Location"
            case .contact:
                name = strings.Attachment_Contact
                animationName = "anim_contact"
                imageName = "Chat/Attach Menu/Contact"
            case .poll:
                name = strings.Attachment_Poll
                animationName = "anim_poll"
                imageName = "Chat/Attach Menu/Poll"
            case let .app(appName):
                name = appName
                animationName = nil
                imageName = nil
            }
            
            let image = imageName.flatMap { UIImage(bundleImageName: $0)?.withRenderingMode(.alwaysTemplate) }
            let tintColor = component.isSelected ? component.theme.rootController.tabBar.selectedIconColor : component.theme.rootController.tabBar.iconColor
            
            let icon = icon.update(
                component: Image(image: image, tintColor: tintColor),
                availableSize: CGSize(width: 30.0, height: 30.0),
                transition: context.transition
            )
            
            print(animationName ?? "")

            let title = title.update(
                component: Text(
                    text: name,
                    font: Font.regular(10.0),
                    color: context.component.isSelected ? component.theme.rootController.tabBar.selectedTextColor : component.theme.rootController.tabBar.textColor
                ),
                availableSize: context.availableSize,
                transition: .immediate
            )

            let topInset: CGFloat = 5.0 + UIScreenPixel
            let spacing: CGFloat = 15.0 + UIScreenPixel
            
            let iconFrame = CGRect(origin: CGPoint(x: floorToScreenPixels((context.availableSize.width - icon.size.width) / 2.0), y: topInset), size: icon.size)
            let titleFrame = CGRect(origin: CGPoint(x: floorToScreenPixels((context.availableSize.width - title.size.width) / 2.0), y: iconFrame.midY + spacing), size: title.size)
            
            context.add(title
                .position(CGPoint(x: titleFrame.midX, y: titleFrame.midY))
                .gesture(.tap {
                    component.action()
                })
            )

            context.add(icon
                .position(CGPoint(x: iconFrame.midX, y: iconFrame.midY))
                .gesture(.tap {
                    component.action()
                })
            )
            
            return context.availableSize
        }
    }
}

final class AttachmentPanel: ASDisplayNode, UIScrollViewDelegate {
    private let context: AccountContext
    private var presentationData: PresentationData
    
    private var presentationInterfaceState: ChatPresentationInterfaceState
    private var interfaceInteraction: ChatPanelInterfaceInteraction?
    
    private let containerNode: ASDisplayNode
    private var effectView: UIVisualEffectView?
    private let scrollNode: ASScrollNode
    private let backgroundNode: ASDisplayNode
    private let separatorNode: ASDisplayNode
    private var buttonViews: [Int: ComponentHostView<Empty>] = [:]
    
    private var textInputPanelNode: AttachmentTextInputPanelNode?
    
    private var buttons: [AttachmentButtonType] = []
    private var selectedIndex: Int = 1
    private(set) var isCollapsed: Bool = false
    private(set) var isSelecting: Bool = false
    
    private var validLayout: ContainerViewLayout?
    private var scrollLayout: (width: CGFloat, contentSize: CGSize)?
    
    var selectionChanged: (AttachmentButtonType, Bool) -> Void = { _, _ in }
    var beganTextEditing: () -> Void = {}
    var textUpdated: (NSAttributedString) -> Void = { _ in }
    var sendMessagePressed: (AttachmentTextInputPanelSendMode) -> Void = { _ in }
    var requestLayout: () -> Void = {}
    var present: (ViewController) -> Void = { _ in }
    var presentInGlobalOverlay: (ViewController) -> Void = { _ in }
    
    init(context: AccountContext) {
        self.context = context
        self.presentationData = context.sharedContext.currentPresentationData.with { $0 }
                
        self.presentationInterfaceState = ChatPresentationInterfaceState(chatWallpaper: .builtin(WallpaperSettings()), theme: self.presentationData.theme, strings: self.presentationData.strings, dateTimeFormat: self.presentationData.dateTimeFormat, nameDisplayOrder: self.presentationData.nameDisplayOrder, limitsConfiguration: self.context.currentLimitsConfiguration.with { $0 }, fontSize: self.presentationData.chatFontSize, bubbleCorners: self.presentationData.chatBubbleCorners, accountPeerId: self.context.account.peerId, mode: .standard(previewing: false), chatLocation: .peer(PeerId(0)), subject: nil, peerNearbyData: nil, greetingData: nil, pendingUnpinnedAllMessages: false, activeGroupCallInfo: nil, hasActiveGroupCall: false, importState: nil)
        
        self.containerNode = ASDisplayNode()
        self.containerNode.clipsToBounds = true
        
        self.scrollNode = ASScrollNode()
        self.backgroundNode = ASDisplayNode()
        self.backgroundNode.backgroundColor = self.presentationData.theme.actionSheet.itemBackgroundColor
        
        self.separatorNode = ASDisplayNode()
        self.separatorNode.backgroundColor = self.presentationData.theme.rootController.navigationBar.separatorColor
        
        super.init()
                        
        self.addSubnode(self.containerNode)
        self.containerNode.addSubnode(self.backgroundNode)
        self.containerNode.addSubnode(self.separatorNode)
        self.containerNode.addSubnode(self.scrollNode)
        
        self.interfaceInteraction = ChatPanelInterfaceInteraction(setupReplyMessage: { _, _ in
        }, setupEditMessage: { _, _ in
        }, beginMessageSelection: { _, _ in
        }, deleteSelectedMessages: {
        }, reportSelectedMessages: {
        }, reportMessages: { _, _ in
        }, blockMessageAuthor: { _, _ in
        }, deleteMessages: { _, _, f in
            f(.default)
        }, forwardSelectedMessages: {
        }, forwardCurrentForwardMessages: {
        }, forwardMessages: { _ in
        }, updateForwardOptionsState: { [weak self] value in
            if let strongSelf = self {
                strongSelf.updateChatPresentationInterfaceState(animated: true, { $0.updatedInterfaceState({ $0.withUpdatedForwardOptionsState($0.forwardOptionsState) }) })
            }
        }, presentForwardOptions: { _ in
        }, shareSelectedMessages: {
        }, updateTextInputStateAndMode: { [weak self] f in
            if let strongSelf = self {
                strongSelf.updateChatPresentationInterfaceState(animated: true, { state in
                    let (updatedState, updatedMode) = f(state.interfaceState.effectiveInputState, state.inputMode)
                    return state.updatedInterfaceState { interfaceState in
                        return interfaceState.withUpdatedEffectiveInputState(updatedState)
                    }.updatedInputMode({ _ in updatedMode })
                })
            }
        }, updateInputModeAndDismissedButtonKeyboardMessageId: { [weak self] f in
            if let strongSelf = self {
                strongSelf.updateChatPresentationInterfaceState(animated: true, {
                    let (updatedInputMode, updatedClosedButtonKeyboardMessageId) = f($0)
                    return $0.updatedInputMode({ _ in return updatedInputMode }).updatedInterfaceState({
                        $0.withUpdatedMessageActionsState({ value in
                            var value = value
                            value.closedButtonKeyboardMessageId = updatedClosedButtonKeyboardMessageId
                            return value
                        })
                    })
                })
            }
        }, openStickers: {
        }, editMessage: {
        }, beginMessageSearch: { _, _ in
        }, dismissMessageSearch: {
        }, updateMessageSearch: { _ in
        }, openSearchResults: {
        }, navigateMessageSearch: { _ in
        }, openCalendarSearch: {
        }, toggleMembersSearch: { _ in
        }, navigateToMessage: { _, _, _, _ in
        }, navigateToChat: { _ in
        }, navigateToProfile: { _ in
        }, openPeerInfo: {
        }, togglePeerNotifications: {
        }, sendContextResult: { _, _, _, _ in
            return false
        }, sendBotCommand: { _, _ in
        }, sendBotStart: { _ in
        }, botSwitchChatWithPayload: { _, _ in
        }, beginMediaRecording: { _ in
        }, finishMediaRecording: { _ in
        }, stopMediaRecording: {
        }, lockMediaRecording: {
        }, deleteRecordedMedia: {
        }, sendRecordedMedia: { _ in
        }, displayRestrictedInfo: { _, _ in
        }, displayVideoUnmuteTip: { _ in
        }, switchMediaRecordingMode: {
        }, setupMessageAutoremoveTimeout: {
        }, sendSticker: { _, _, _, _ in
            return false
        }, unblockPeer: {
        }, pinMessage: { _, _ in
        }, unpinMessage: { _, _, _ in
        }, unpinAllMessages: {
        }, openPinnedList: { _ in
        }, shareAccountContact: {
        }, reportPeer: {
        }, presentPeerContact: {
        }, dismissReportPeer: {
        }, deleteChat: {
        }, beginCall: { _ in
        }, toggleMessageStickerStarred: { _ in
        }, presentController: { _, _ in
        }, getNavigationController: {
            return nil
        }, presentGlobalOverlayController: { _, _ in
        }, navigateFeed: {
        }, openGrouping: {
        }, toggleSilentPost: {
        }, requestUnvoteInMessage: { _ in
        }, requestStopPollInMessage: { _ in
        }, updateInputLanguage: { _ in
        }, unarchiveChat: {
        }, openLinkEditing: { [weak self] in
            if let strongSelf = self {
                var selectionRange: Range<Int>?
                var text: String?
                var inputMode: ChatInputMode?

                strongSelf.updateChatPresentationInterfaceState(animated: true, { state in
                    selectionRange = state.interfaceState.effectiveInputState.selectionRange
                    if let selectionRange = selectionRange {
                        text = state.interfaceState.effectiveInputState.inputText.attributedSubstring(from: NSRange(location: selectionRange.startIndex, length: selectionRange.count)).string
                    }
                    inputMode = state.inputMode
                    return state
                })

                let presentationData = strongSelf.context.sharedContext.currentPresentationData.with { $0 }
                let controller = chatTextLinkEditController(sharedContext: strongSelf.context.sharedContext, updatedPresentationData: (presentationData, .never()), account: strongSelf.context.account, text: text ?? "", link: nil, apply: { [weak self] link in
                    if let strongSelf = self, let inputMode = inputMode, let selectionRange = selectionRange {
                        if let link = link {
                            strongSelf.updateChatPresentationInterfaceState(animated: true, { state in
                                return state.updatedInterfaceState({
                                    $0.withUpdatedEffectiveInputState(chatTextInputAddLinkAttribute($0.effectiveInputState, selectionRange: selectionRange, url: link))
                                })
                            })
                        }
                        if let textInputPanelNode = strongSelf.textInputPanelNode {
                            textInputPanelNode.ensureFocused()
                        }
                        strongSelf.updateChatPresentationInterfaceState(animated: true, { state in
                            return state.updatedInputMode({ _ in return inputMode }).updatedInterfaceState({
                                $0.withUpdatedEffectiveInputState(ChatTextInputState(inputText: $0.effectiveInputState.inputText, selectionRange: selectionRange.endIndex ..< selectionRange.endIndex))
                            })
                        })
                    }
                })
                strongSelf.present(controller)
            }
        }, reportPeerIrrelevantGeoLocation: {
        }, displaySlowmodeTooltip: { _, _ in
        }, displaySendMessageOptions: { [weak self] node, gesture in
            guard let strongSelf = self, let textInputPanelNode = strongSelf.textInputPanelNode else {
                return
            }
            textInputPanelNode.loadTextInputNodeIfNeeded()
            guard let textInputNode = textInputPanelNode.textInputNode else {
                return
            }
            let controller = ChatSendMessageActionSheetController(context: strongSelf.context, interfaceState: strongSelf.presentationInterfaceState, gesture: gesture, sourceSendButton: node, textInputNode: textInputNode, completion: {
            }, sendMessage: { [weak textInputPanelNode] silently in
                textInputPanelNode?.sendMessage(silently ? .silent : .generic)
            }, schedule: { [weak textInputPanelNode] in
                textInputPanelNode?.sendMessage(.schedule)
            })
            strongSelf.presentInGlobalOverlay(controller)
        }, openScheduledMessages: {
        }, openPeersNearby: {
        }, displaySearchResultsTooltip: { _, _ in
        }, unarchivePeer: {
        }, scrollToTop: {
        }, viewReplies: { _, _ in
        }, activatePinnedListPreview: { _, _ in
        }, joinGroupCall: { _ in
        }, presentInviteMembers: {
        }, presentGigagroupHelp: {
        }, editMessageMedia: { _, _ in
        }, updateShowCommands: { _ in
        }, updateShowSendAsPeers: { _ in
        }, openInviteRequests: {
        }, openSendAsPeer: { _, _ in
        }, presentChatRequestAdminInfo: {
        }, displayCopyProtectionTip: { _, _ in
        }, statuses: nil)
    }
    
    override func didLoad() {
        super.didLoad()
        if #available(iOS 13.0, *) {
            self.containerNode.layer.cornerCurve = .continuous
        }
    
        self.scrollNode.view.delegate = self
        self.scrollNode.view.showsHorizontalScrollIndicator = false
        self.scrollNode.view.showsVerticalScrollIndicator = false
        
        let effect: UIVisualEffect
        switch self.presentationData.theme.actionSheet.backgroundType {
        case .light:
            effect = UIBlurEffect(style: .light)
        case .dark:
            effect = UIBlurEffect(style: .dark)
        }
        let effectView = UIVisualEffectView(effect: effect)
        self.effectView = effectView
        self.containerNode.view.insertSubview(effectView, at: 0)
    }
    
    func updateCaption(_ caption: NSAttributedString) {
        if !caption.string.isEmpty {
            self.loadTextNodeIfNeeded()
        }
        self.updateChatPresentationInterfaceState(animated: false, { $0.updatedInterfaceState { $0.withUpdatedComposeInputState(ChatTextInputState(inputText: caption))} })
    }
    
    private func updateChatPresentationInterfaceState(animated: Bool = true, _ f: (ChatPresentationInterfaceState) -> ChatPresentationInterfaceState, completion: @escaping (ContainedViewLayoutTransition) -> Void = { _ in }) {
        self.updateChatPresentationInterfaceState(transition: animated ? .animated(duration: 0.4, curve: .spring) : .immediate, f, completion: completion)
    }
    
    private func updateChatPresentationInterfaceState(transition: ContainedViewLayoutTransition, _ f: (ChatPresentationInterfaceState) -> ChatPresentationInterfaceState, completion externalCompletion: @escaping (ContainedViewLayoutTransition) -> Void = { _ in }) {
        let presentationInterfaceState = f(self.presentationInterfaceState)
        let updateInputTextState = self.presentationInterfaceState.interfaceState.effectiveInputState != presentationInterfaceState.interfaceState.effectiveInputState
        
        self.presentationInterfaceState = presentationInterfaceState
        
        if let textInputPanelNode = self.textInputPanelNode, updateInputTextState {
            textInputPanelNode.updateInputTextState(presentationInterfaceState.interfaceState.effectiveInputState, animated: transition.isAnimated)

            self.textUpdated(presentationInterfaceState.interfaceState.effectiveInputState.inputText)
        }
    }
    
    func updateViews(transition: Transition) {
        guard let layout = self.validLayout else {
            return
        }
        
        let visibleRect = self.scrollNode.bounds.insetBy(dx: -180.0, dy: 0.0)
        let actualVisibleRect = self.scrollNode.bounds
        var validButtons = Set<Int>()
        
        var sideInset = sideInset
        let buttonsWidth = sideInset * 2.0 + buttonSize.width * CGFloat(self.buttons.count)
        if buttonsWidth < layout.size.width {
            sideInset = floorToScreenPixels((layout.size.width - buttonsWidth) / 2.0)
        }
        
        for i in 0 ..< self.buttons.count {
            let buttonFrame = CGRect(origin: CGPoint(x: sideInset + buttonSize.width * CGFloat(i), y: 0.0), size: buttonSize)
            if !visibleRect.intersects(buttonFrame) {
                continue
            }
            validButtons.insert(i)
            
            let edge = buttonSize.width * 0.75
            let leftEdge = max(-edge, min(0.0, buttonFrame.minX - actualVisibleRect.minX)) / -edge
            let rightEdge = min(edge, max(0.0, buttonFrame.maxX - actualVisibleRect.maxX)) / edge
            
            let transitionFraction: CGFloat
            if leftEdge > rightEdge {
                transitionFraction = leftEdge
            } else {
                transitionFraction = -rightEdge
            }
            
            var buttonTransition = transition
            let buttonView: ComponentHostView<Empty>
            if let current = self.buttonViews[i] {
                buttonView = current
            } else {
                buttonTransition = .immediate
                buttonView = ComponentHostView<Empty>()
                self.buttonViews[i] = buttonView
                self.scrollNode.view.addSubview(buttonView)
            }
            
            let type = self.buttons[i]
            let _ = buttonView.update(
                transition: buttonTransition,
                component: AnyComponent(AttachButtonComponent(
                    context: self.context,
                    type: type,
                    isSelected: i == self.selectedIndex,
                    isCollapsed: self.isCollapsed,
                    transitionFraction: transitionFraction,
                    strings: self.presentationData.strings,
                    theme: self.presentationData.theme,
                    action: { [weak self] in
                        if let strongSelf = self {
                            let ascending = i > strongSelf.selectedIndex
                            strongSelf.selectedIndex = i
                            strongSelf.selectionChanged(type, ascending)
                            strongSelf.updateViews(transition: .init(animation: .curve(duration: 0.2, curve: .spring)))
                        }
                    })
                ),
                environment: {},
                containerSize: buttonSize
            )
            buttonTransition.setFrame(view: buttonView, frame: buttonFrame)
        }
    }
    
    private func updateScrollLayoutIfNeeded(force: Bool, transition: ContainedViewLayoutTransition) -> Bool {
        guard let layout = self.validLayout else {
            return false
        }
        if self.scrollLayout?.width == layout.size.width && !force {
            return false
        }
        
        var sideInset = sideInset
        let buttonsWidth = sideInset * 2.0 + buttonSize.width * CGFloat(self.buttons.count)
        if buttonsWidth < layout.size.width {
            sideInset = floorToScreenPixels((layout.size.width - buttonsWidth) / 2.0)
        }

        let contentSize = CGSize(width: sideInset * 2.0 + CGFloat(self.buttons.count) * buttonSize.width, height: buttonSize.height)
        self.scrollLayout = (layout.size.width, contentSize)

        transition.updateFrame(node: self.scrollNode, frame: CGRect(origin: CGPoint(x: 0.0, y: self.isSelecting ? -buttonSize.height : 0.0), size: CGSize(width: layout.size.width, height: buttonSize.height)))
        self.scrollNode.view.contentSize = contentSize

        return true
    }
    
    private func loadTextNodeIfNeeded() {
        if let _ = self.textInputPanelNode {
        } else {
            let textInputPanelNode = AttachmentTextInputPanelNode(context: self.context, presentationInterfaceState: self.presentationInterfaceState, isAttachment: true, presentController: { [weak self] c in
                if let strongSelf = self {
                    strongSelf.present(c)
                }
            })
            textInputPanelNode.interfaceInteraction = self.interfaceInteraction
            textInputPanelNode.sendMessage = { [weak self] mode in
                if let strongSelf = self {
                    strongSelf.sendMessagePressed(mode)
                }
            }
            textInputPanelNode.focusUpdated = { [weak self] focus in
                if let strongSelf = self, focus {
                    strongSelf.beganTextEditing()
                }
            }
            textInputPanelNode.updateHeight = { [weak self] _ in
                if let strongSelf = self {
                    strongSelf.requestLayout()
                }
            }
            self.addSubnode(textInputPanelNode)
            self.textInputPanelNode = textInputPanelNode
            
            textInputPanelNode.alpha = self.isSelecting ? 1.0 : 0.0
            textInputPanelNode.isUserInteractionEnabled = self.isSelecting
        }
    }
    
    func update(layout: ContainerViewLayout, buttons: [AttachmentButtonType], isCollapsed: Bool, isSelecting: Bool, transition: ContainedViewLayoutTransition) -> CGFloat {
        self.validLayout = layout
        self.buttons = buttons
        
        let isCollapsedUpdated = self.isCollapsed != isCollapsed
        self.isCollapsed = isCollapsed
                
        let isSelectingUpdated = self.isSelecting != isSelecting
        self.isSelecting = isSelecting
        
        self.scrollNode.isUserInteractionEnabled = !isSelecting
        
        var insets = layout.insets(options: [])
        if let inputHeight = layout.inputHeight, inputHeight > 0.0 && isSelecting {
            insets.bottom = inputHeight
        } else if layout.intrinsicInsets.bottom > 0.0 {
            insets.bottom = layout.intrinsicInsets.bottom
        }
        
        if isSelecting {
            self.loadTextNodeIfNeeded()
        } else {
            self.textInputPanelNode?.ensureUnfocused()
        }
        var textPanelHeight: CGFloat = 0.0
        if let textInputPanelNode = self.textInputPanelNode {
            textInputPanelNode.isUserInteractionEnabled = isSelecting
            
            var panelTransition = transition
            if textInputPanelNode.frame.width.isZero {
                panelTransition = .immediate
            }
            let panelHeight = textInputPanelNode.updateLayout(width: layout.size.width, leftInset: insets.left, rightInset: insets.right, additionalSideInsets: UIEdgeInsets(), maxHeight: layout.size.height / 2.0, isSecondary: false, transition: panelTransition, interfaceState: self.presentationInterfaceState, metrics: layout.metrics)
            let panelFrame = CGRect(x: 0.0, y: 0.0, width: layout.size.width, height: panelHeight)
            if textInputPanelNode.frame.width.isZero {
                textInputPanelNode.frame = panelFrame
            }
            transition.updateFrame(node: textInputPanelNode, frame: panelFrame)
            if panelFrame.height > 0.0 {
                textPanelHeight = panelFrame.height
            } else {
                textPanelHeight = 45.0
            }
        }
        
        let bounds = CGRect(origin: CGPoint(), size: CGSize(width: layout.size.width, height: buttonSize.height + insets.bottom))
        let containerTransition: ContainedViewLayoutTransition
        let containerFrame: CGRect
        if isSelecting {
            containerFrame = CGRect(origin: CGPoint(), size: CGSize(width: bounds.width, height: textPanelHeight + insets.bottom))
        } else {
            containerFrame = bounds
        }
        let containerBounds = CGRect(origin: CGPoint(), size: containerFrame.size)
        if isCollapsedUpdated || isSelectingUpdated {
            containerTransition = .animated(duration: 0.25, curve: .easeInOut)
        } else {
            containerTransition = transition
        }
        containerTransition.updateAlpha(node: self.scrollNode, alpha: isSelecting ? 0.0 : 1.0)
        
        if isSelectingUpdated {
            if isSelecting {
                self.loadTextNodeIfNeeded()
                if let textInputPanelNode = self.textInputPanelNode {
                    textInputPanelNode.alpha = 1.0
                    textInputPanelNode.layer.animateAlpha(from: 0.0, to: 1.0, duration: 0.25)
                    textInputPanelNode.layer.animatePosition(from: CGPoint(x: 0.0, y: 44.0), to: CGPoint(), duration: 0.25, additive: true)
                }
            } else {
                if let textInputPanelNode = self.textInputPanelNode {
                    textInputPanelNode.alpha = 0.0
                    textInputPanelNode.layer.animateAlpha(from: 1.0, to: 0.0, duration: 0.25)
                    textInputPanelNode.layer.animatePosition(from: CGPoint(), to: CGPoint(x: 0.0, y: 44.0), duration: 0.25, additive: true)
                }
            }
        }

        
        containerTransition.updateFrame(node: self.containerNode, frame: containerFrame)
        containerTransition.updateFrame(node: self.backgroundNode, frame: containerBounds)
        containerTransition.updateFrame(node: self.separatorNode, frame: CGRect(origin: CGPoint(), size: CGSize(width: bounds.width, height: UIScreenPixel)))
        if let effectView = self.effectView {
            containerTransition.updateFrame(view: effectView, frame: bounds)
        }
                
        let _ = self.updateScrollLayoutIfNeeded(force: isCollapsedUpdated || isSelectingUpdated, transition: containerTransition)

        var buttonTransition: Transition = .immediate
        if isCollapsedUpdated {
            buttonTransition = .easeInOut(duration: 0.25)
        }
        self.updateViews(transition: buttonTransition)
        
        return containerFrame.height
    }
    
    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        self.updateViews(transition: .immediate)
    }
}