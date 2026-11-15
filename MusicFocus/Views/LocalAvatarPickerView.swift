//
//  LocalAvatarPickerView.swift
//  MusicFocus
//
//  本地头像选择器（无需网络）
//

import SwiftUI

/**
 * @struct LocalAvatarPickerView
 * @description 本地头像选择器视图
 */
struct LocalAvatarPickerView: View {
    @Environment(\.dismiss) var dismiss
    @EnvironmentObject var focusManager: FocusManager
    @ObservedObject var avatarManager: LocalAvatarManager

    @State private var selectedCategory: LocalAvatar.AvatarCategory? = nil

    private var filteredAvatars: [LocalAvatar] {
        if let category = selectedCategory {
            return LocalAvatar.presets.filter { $0.category == category }
        }
        return LocalAvatar.presets
    }

    var body: some View {
        NavigationView {
            ScrollView {
                VStack(spacing: 24) {
                    // 分类筛选器
                    CategoryFilterSection(selectedCategory: $selectedCategory)

                    // 头像网格
                    AvatarGridSection(
                        avatars: filteredAvatars,
                        currentAvatar: avatarManager.currentAvatar,
                        onSelect: { avatar in
                            avatarManager.saveAvatar(avatar)
                            dismiss()
                        }
                    )

                    // 推荐头像（根据最高勋章）
                    RecommendedAvatarSection(
                        avatarManager: avatarManager,
                        onSelect: { avatar in
                            avatarManager.saveAvatar(avatar)
                            dismiss()
                        }
                    )
                }
                .padding()
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("Choose Your Avatar".localized)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Cancel".localized) {
                        dismiss()
                    }
                }
            }
        }
    }
}

/**
 * @struct CategoryFilterSection
 * @description 分类筛选器
 */
struct CategoryFilterSection: View {
    @Binding var selectedCategory: LocalAvatar.AvatarCategory?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Filter by Category".localized)
                .font(.headline)
                .foregroundColor(.primary)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 12) {
                    // "All" button
                    CategoryChip(
                        title: "All".localized,
                        isSelected: selectedCategory == nil,
                        action: {
                            withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                                selectedCategory = nil
                            }
                        }
                    )

                    // Category buttons
                    ForEach(LocalAvatar.AvatarCategory.allCases, id: \.self) { category in
                        CategoryChip(
                            title: category.rawValue,
                            isSelected: selectedCategory == category,
                            action: {
                                withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                                    selectedCategory = category
                                }
                            }
                        )
                    }
                }
                .padding(.horizontal, 4)
            }
        }
        .padding()
        .background(Color(.secondarySystemBackground))
        .cornerRadius(12)
    }
}

/**
 * @struct CategoryChip
 * @description 分类筛选按钮
 */
struct CategoryChip: View {
    let title: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.subheadline)
                .fontWeight(isSelected ? .semibold : .regular)
                .foregroundColor(isSelected ? .white : .primary)
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .background(
                    Capsule()
                        .fill(isSelected ? Color.blue : Color(.tertiarySystemBackground))
                )
        }
    }
}

/**
 * @struct AvatarGridSection
 * @description 头像网格展示
 */
struct AvatarGridSection: View {
    let avatars: [LocalAvatar]
    let currentAvatar: LocalAvatar
    let onSelect: (LocalAvatar) -> Void

    private let columns = [
        GridItem(.flexible(), spacing: 16),
        GridItem(.flexible(), spacing: 16),
        GridItem(.flexible(), spacing: 16)
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Available Avatars".localized)
                .font(.headline)
                .foregroundColor(.primary)

            LazyVGrid(columns: columns, spacing: 16) {
                ForEach(avatars) { avatar in
                    AvatarCard(
                        avatar: avatar,
                        isSelected: avatar.id == currentAvatar.id,
                        onTap: { onSelect(avatar) }
                    )
                }
            }
        }
        .padding()
        .background(Color(.secondarySystemBackground))
        .cornerRadius(12)
    }
}

/**
 * @struct AvatarCard
 * @description 单个头像卡片
 */
struct AvatarCard: View {
    let avatar: LocalAvatar
    let isSelected: Bool
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            VStack(spacing: 8) {
                ZStack {
                    // 背景圆圈
                    Circle()
                        .fill(avatar.color.opacity(0.2))
                        .frame(width: 80, height: 80)

                    // SF Symbol图标
                    Image(systemName: avatar.iconName)
                        .font(.system(size: 40))
                        .foregroundColor(avatar.color)

                    // 选中标记
                    if isSelected {
                        Circle()
                            .stroke(Color.blue, lineWidth: 3)
                            .frame(width: 80, height: 80)

                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 24))
                            .foregroundColor(.blue)
                            .background(Circle().fill(Color.white).frame(width: 26, height: 26))
                            .offset(x: 30, y: -30)
                    }
                }

                Text(avatar.displayName)
                    .font(.caption)
                    .fontWeight(isSelected ? .semibold : .regular)
                    .foregroundColor(isSelected ? .blue : .primary)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
            }
            .padding(8)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color(.tertiarySystemBackground))
                    .shadow(color: isSelected ? Color.blue.opacity(0.3) : Color.clear, radius: 8, x: 0, y: 4)
            )
        }
        .buttonStyle(PlainButtonStyle())
    }
}

/**
 * @struct RecommendedAvatarSection
 * @description 推荐头像区域
 */
struct RecommendedAvatarSection: View {
    @EnvironmentObject var focusManager: FocusManager
    @ObservedObject var avatarManager: LocalAvatarManager
    let onSelect: (LocalAvatar) -> Void

    private var recommendedAvatar: LocalAvatar? {
        guard let highest = focusManager.badgeManager.badges.max(by: { $0.level.timeRange.lowerBound < $1.level.timeRange.lowerBound }) else {
            return nil
        }
        return LocalAvatar.recommendedForBadge(highest.level)
    }

    var body: some View {
        if let avatar = recommendedAvatar {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Image(systemName: "star.fill")
                        .foregroundColor(.yellow)

                    Text("Recommended for You".localized)
                        .font(.headline)
                        .foregroundColor(.primary)
                }

                HStack(spacing: 16) {
                    // 头像预览
                    ZStack {
                        Circle()
                            .fill(avatar.color.opacity(0.2))
                            .frame(width: 80, height: 80)

                        Image(systemName: avatar.iconName)
                            .font(.system(size: 40))
                            .foregroundColor(avatar.color)
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        Text(avatar.displayName)
                            .font(.title3)
                            .fontWeight(.semibold)

                        Text("Based on your highest badge".localized)
                            .font(.caption)
                            .foregroundColor(.secondary)

                        Button(action: { onSelect(avatar) }) {
                            Text("Select This Avatar".localized)
                                .font(.subheadline)
                                .fontWeight(.semibold)
                                .foregroundColor(.white)
                                .padding(.horizontal, 16)
                                .padding(.vertical, 8)
                                .background(Capsule().fill(Color.blue))
                        }
                    }

                    Spacer()
                }
                .padding()
                .background(
                    RoundedRectangle(cornerRadius: 12)
                        .fill(Color(.tertiarySystemBackground))
                )
            }
            .padding()
            .background(Color(.secondarySystemBackground))
            .cornerRadius(12)
        }
    }
}

#Preview {
    let focusManager = FocusManager()
    let avatarManager = LocalAvatarManager()
    return LocalAvatarPickerView(avatarManager: avatarManager)
        .environmentObject(focusManager)
}
