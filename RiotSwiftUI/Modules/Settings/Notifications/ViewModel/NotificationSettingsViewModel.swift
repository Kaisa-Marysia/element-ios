// File created from ScreenTemplate
// $ createScreen.sh Settings/Notifications NotificationSettings
/*
 Copyright 2021 New Vector Ltd
 
 Licensed under the Apache License, Version 2.0 (the "License");
 you may not use this file except in compliance with the License.
 You may obtain a copy of the License at
 
 http://www.apache.org/licenses/LICENSE-2.0
 
 Unless required by applicable law or agreed to in writing, software
 distributed under the License is distributed on an "AS IS" BASIS,
 WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 See the License for the specific language governing permissions and
 limitations under the License.
 */

import Combine
import Foundation
import SwiftUI

final class NotificationSettingsViewModel: NotificationSettingsViewModelType, ObservableObject {
    // MARK: - Properties
    
    // MARK: Private
    
    private let notificationSettingsService: NotificationSettingsServiceType
    // The rule ids this view model allows the ui to enabled/disable.
    private let ruleIds: [NotificationPushRuleId]
    private var cancellables = Set<AnyCancellable>()
    
    // The ordered array of keywords the UI displays.
    // We keep it ordered so keywords don't jump around when being added and removed.
    @Published private var keywordsOrdered = [String]()
    
    // MARK: Public
    
    @Published var viewState: NotificationSettingsViewState
    
    weak var coordinatorDelegate: NotificationSettingsViewModelCoordinatorDelegate?
    
    // MARK: - Setup
    
    init(notificationSettingsService: NotificationSettingsServiceType, ruleIds: [NotificationPushRuleId], initialState: NotificationSettingsViewState) {
        self.notificationSettingsService = notificationSettingsService
        self.ruleIds = ruleIds
        viewState = initialState
        
        // Observe when the rules are updated, to subsequently update the state of the settings.
        notificationSettingsService.rulesPublisher
            .sink { [weak self] newRules in
                self?.rulesUpdated(newRules: newRules)
            }
            .store(in: &cancellables)
        
        // Only observe keywords if the current settings view displays it.
        if ruleIds.contains(.keywords) {
            // Publisher of all the keyword push rules (keyword rules do not start with '.')
            let keywordsRules = notificationSettingsService.contentRulesPublisher
                .map { $0.filter { !$0.ruleId.starts(with: ".") } }
            
            // Map to just the keyword strings
            let keywords = keywordsRules
                .map { Set($0.compactMap(\.ruleId)) }
            
            // Update the keyword set
            keywords
                .sink { [weak self] updatedKeywords in
                    guard let self = self else { return }
                    // We avoid simply assigning the new set as it would cause all keywords to get sorted lexigraphically.
                    // We first sort lexigraphically, and secondly preserve the order the user added them.
                    // The following adds/removes any updates while preserving that ordering.
                    
                    // Remove keywords not in the updated set.
                    var newKeywordsOrdered = self.keywordsOrdered.filter { keyword in
                        updatedKeywords.contains(keyword)
                    }
                    // Append items in the updated set if they are not already added.
                    // O(n)² here. Will change keywordsOrdered back to an `OrderedSet` in future to fix this.
                    updatedKeywords.sorted().forEach { keyword in
                        if !newKeywordsOrdered.contains(keyword) {
                            newKeywordsOrdered.append(keyword)
                        }
                    }
                    self.keywordsOrdered = newKeywordsOrdered
                }
                .store(in: &cancellables)
            
            // Keyword rules were updates, check if we need to update the setting.
            keywordsRules
                .map { $0.contains { $0.enabled } }
                .sink { [weak self] in
                    self?.keywordRuleUpdated(anyEnabled: $0)
                }
                .store(in: &cancellables)
            
            // Update the viewState with the final keywords to be displayed.
            $keywordsOrdered
                .weakAssign(to: \.viewState.keywords, on: self)
                .store(in: &cancellables)
        }
    }
    
    convenience init(notificationSettingsService: NotificationSettingsServiceType, ruleIds: [NotificationPushRuleId]) {
        let ruleState = Dictionary(uniqueKeysWithValues: ruleIds.map { ($0, selected: true) })
        self.init(notificationSettingsService: notificationSettingsService, ruleIds: ruleIds, initialState: NotificationSettingsViewState(saving: false, ruleIds: ruleIds, selectionState: ruleState))
    }
    
    // MARK: - Public
    
    @MainActor
    func update(ruleID: NotificationPushRuleId, isChecked: Bool) async {
        let index = NotificationIndex.index(when: isChecked)
        let standardActions = ruleID.standardActions(for: index)
        let enabled = standardActions != .disabled
        
        switch ruleID {
        case .keywords: // Keywords is handled differently to other settings
            await updateKeywords(isChecked: isChecked)

        case .oneToOneRoom, .allOtherMessages:
            await updatePushAction(
                id: ruleID,
                enabled: enabled,
                standardActions: standardActions,
                then: ruleID.syncedRules
            )

        default:
            try? await notificationSettingsService.updatePushRuleActions(
                for: ruleID.rawValue,
                enabled: enabled,
                actions: standardActions.actions
            )
        }
    }
    
    func add(keyword: String) {
        if !keywordsOrdered.contains(keyword) {
            keywordsOrdered.append(keyword)
        }
        notificationSettingsService.add(keyword: keyword, enabled: true)
    }
    
    func remove(keyword: String) {
        keywordsOrdered = keywordsOrdered.filter { $0 != keyword }
        notificationSettingsService.remove(keyword: keyword)
    }
    
    func isRuleOutOfSync(_ ruleId: NotificationPushRuleId) -> Bool {
        viewState.outOfSyncRules.contains(ruleId) && viewState.saving == false
    }
}

// MARK: - Private

private extension NotificationSettingsViewModel {
    @MainActor
    func updateKeywords(isChecked: Bool) async {
        guard !keywordsOrdered.isEmpty else {
            viewState.selectionState[.keywords]?.toggle()
            return
        }
        
        // Get the static definition and update the actions and enabled state for every keyword.
        let index = NotificationIndex.index(when: isChecked)
        let standardActions = NotificationPushRuleId.keywords.standardActions(for: index)
        let enabled = standardActions != .disabled
        let keywordsToUpdate = keywordsOrdered
        
        await withThrowingTaskGroup(of: Void.self) { group in
            for keyword in keywordsToUpdate {
                group.addTask {
                    try await self.notificationSettingsService.updatePushRuleActions(
                        for: keyword,
                        enabled: enabled,
                        actions: standardActions.actions
                    )
                }
            }
        }
    }

    func updatePushAction(id: NotificationPushRuleId,
                          enabled: Bool,
                          standardActions: NotificationStandardActions,
                          then rules: [NotificationPushRuleId]) async {
        await MainActor.run {
            viewState.saving = true
        }
        
        do {
            // update the 'parent rule' first
            try await notificationSettingsService.updatePushRuleActions(for: id.rawValue, enabled: enabled, actions: standardActions.actions)
            
            // synchronize all the 'children rules' with the parent rule
            await withThrowingTaskGroup(of: Void.self) { group in
                for ruleId in rules {
                    group.addTask {
                        try await self.notificationSettingsService.updatePushRuleActions(for: ruleId.rawValue, enabled: enabled, actions: standardActions.actions)
                    }
                }
            }
            await completeUpdate()
        } catch {
            await completeUpdate()
        }
    }
    
    @MainActor
    func completeUpdate() {
        viewState.saving = false
    }
    
    func rulesUpdated(newRules: [NotificationPushRuleType]) {
        var outOfSyncRules: Set<NotificationPushRuleId> = .init()
        
        for rule in newRules {
            guard
                let ruleId = NotificationPushRuleId(rawValue: rule.ruleId),
                ruleIds.contains(ruleId)
            else {
                continue
            }

            let relatedSyncedRules = ruleId.syncedRules(in: newRules)
            viewState.selectionState[ruleId] = isChecked(rule: rule, syncedRules: relatedSyncedRules)
            
            if isOutOfSync(rule: rule, syncedRules: relatedSyncedRules) {
                outOfSyncRules.insert(ruleId)
            }
        }
        
        viewState.outOfSyncRules = outOfSyncRules
    }
    
    func keywordRuleUpdated(anyEnabled: Bool) {
        if !keywordsOrdered.isEmpty {
            viewState.selectionState[.keywords] = anyEnabled
        }
    }
      
    /// Given a push rule check which index/checked state it matches.
    ///
    /// Matching is done by comparing the rule against the static definitions for that rule.
    /// The same logic is used on android.
    /// - Parameter rule: The push rule type to check.
    /// - Returns: Wether it should be displayed as checked or not checked.
    func defaultIsChecked(rule: NotificationPushRuleType) -> Bool {
        guard let ruleId = NotificationPushRuleId(rawValue: rule.ruleId) else {
            return false
        }
        
        let firstIndex = NotificationIndex.allCases.first { nextIndex in
            rule.matches(standardActions: ruleId.standardActions(for: nextIndex))
        }
        
        guard let index = firstIndex else {
            return false
        }
        
        return index.enabled
    }
    
    func isChecked(rule: NotificationPushRuleType, syncedRules: [NotificationPushRuleType]) -> Bool {
        guard let ruleId = NotificationPushRuleId(rawValue: rule.ruleId) else {
            return false
        }
        
        switch ruleId {
        case .oneToOneRoom, .allOtherMessages:
            let ruleIsChecked = defaultIsChecked(rule: rule)
            let someSyncedRuleIsChecked = syncedRules.contains(where: { defaultIsChecked(rule: $0) })
            // The "loudest" rule will be applied when there is a clash between a rule and its dependent rules.
            return ruleIsChecked || someSyncedRuleIsChecked
        default:
            return defaultIsChecked(rule: rule)
        }
    }
    
    func isOutOfSync(rule: NotificationPushRuleType, syncedRules: [NotificationPushRuleType]) -> Bool {
        guard let ruleId = NotificationPushRuleId(rawValue: rule.ruleId) else {
            return false
        }
        
        switch ruleId {
        case .oneToOneRoom, .allOtherMessages:
            let ruleIsChecked = defaultIsChecked(rule: rule)
            return syncedRules.contains(where: { defaultIsChecked(rule: $0) != ruleIsChecked })
        default:
            return false
        }
    }
}

private extension NotificationPushRuleId {
    func syncedRules(in rules: [NotificationPushRuleType]) -> [NotificationPushRuleType] {
        rules.filter {
            guard let ruleId = NotificationPushRuleId(rawValue: $0.ruleId) else {
                return false
            }
            return syncedRules.contains(ruleId)
        }
    }
}
