import SwiftUI

// MARK: - TG频道管理页面
struct TGChannelListView: View {
    @ObservedObject private var store = TGSearchConfigStore.shared

    @State private var showAddSheet = false
    @State private var newName = ""
    @State private var newChannelId = ""

    var body: some View {
        List {
            // 自定义频道列表
            if store.channels.isEmpty {
                Section {
                    Text("暂无自定义频道")
                        .font(.system(size: 14))
                        .foregroundColor(.secondary)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.vertical, 20)
                }
            } else {
                Section(header: Text("自定义频道（\(store.channels.count) 个）")) {
                    ForEach(store.channels) { channel in
                        HStack {
                            Image(systemName: "line.3.horizontal")
                                .font(.system(size: 14))
                                .foregroundColor(.secondary)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(channel.name)
                                    .font(.system(size: 15, weight: .medium))
                                Text(channel.channelId)
                                    .font(.system(size: 12))
                                    .foregroundColor(.secondary)
                            }
                            Spacer()
                        }
                        .padding(.vertical, 4)
                    }
                    .onDelete { offsets in
                        offsets.forEach { store.removeChannel(at: $0) }
                    }
                    .onMove { source, destination in
                        store.moveChannel(from: source, to: destination)
                    }
                }
            }

            // 快捷添加
            Section(header: Text("快捷添加常用频道")) {
                let presets = TGSearchConfigStore.presetChannels
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                    ForEach(presets, id: \.channelId) { preset in
                        Button {
                            // 避免重复添加
                            if !store.channels.contains(where: { $0.channelId == preset.channelId }) {
                                store.addChannel(name: preset.name, channelId: preset.channelId)
                            }
                        } label: {
                            HStack {
                                Image(systemName: "plus.circle.fill")
                                    .font(.system(size: 13))
                                Text(preset.name)
                                    .font(.system(size: 13, weight: .medium))
                            }
                            .foregroundColor(.accentColor)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 8)
                            .background(
                                RoundedRectangle(cornerRadius: 8)
                                    .fill(Color(uiColor: .tertiarySystemGroupedBackground))
                            )
                        }
                        .buttonStyle(.plain)
                        .disabled(store.channels.contains(where: { $0.channelId == preset.channelId }))
                    }
                }
                .padding(.vertical, 4)
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("TG频道管理")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button {
                    showAddSheet = true
                } label: {
                    Image(systemName: "plus")
                }
            }
            #if os(iOS)
            ToolbarItem(placement: .navigationBarLeading) {
                EditButton()
            }
            #endif
        }
        .sheet(isPresented: $showAddSheet) {
            AddChannelSheet(
                newName: $newName,
                newChannelId: $newChannelId,
                onAdd: {
                    store.addChannel(name: newName, channelId: newChannelId)
                    newName = ""
                    newChannelId = ""
                    showAddSheet = false
                },
                onCancel: {
                    newName = ""
                    newChannelId = ""
                    showAddSheet = false
                }
            )
        }
    }
}

// MARK: - 添加频道 Sheet
struct AddChannelSheet: View {
    @Binding var newName: String
    @Binding var newChannelId: String
    let onAdd: () -> Void
    let onCancel: () -> Void

    var body: some View {
        NavigationView {
            VStack(spacing: 20) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("频道名称")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(.secondary)
                    TextField("如：UC夸克资源", text: $newName)
                        .font(.system(size: 15))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 10)
                        .background(
                            RoundedRectangle(cornerRadius: 8)
                                .fill(Color(uiColor: .tertiarySystemGroupedBackground))
                        )
                }

                VStack(alignment: .leading, spacing: 8) {
                    Text("频道 ID")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(.secondary)
                    TextField("如：ucquark", text: $newChannelId)
                        .font(.system(size: 15))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 10)
                        .background(
                            RoundedRectangle(cornerRadius: 8)
                                .fill(Color(uiColor: .tertiarySystemGroupedBackground))
                        )
                        .autocapitalization(.none)
                        .disableAutocorrection(true)
                    Text("频道 ID 是 t.me/s/ 后面的名称，不含 @ 符号")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                }

                Spacer()
            }
            .padding(20)
            .navigationTitle("添加频道")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("取消") { onCancel() }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("添加") {
                        if !newChannelId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            onAdd()
                        }
                    }
                    .fontWeight(.semibold)
                    .disabled(newChannelId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }
}
