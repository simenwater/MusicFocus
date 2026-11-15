import SwiftUI

/// A small local checklist backed by the original teacher-note records.
/// Editing text/completion never rebuilds a record or discards its older fields.
struct PracticeNotesContent: View {
    @EnvironmentObject private var focusManager: FocusManager
    @State private var addingNote = false
    @State private var editingNote: TeacherNote?

    private var notes: [TeacherNote] {
        focusManager.teacherNotes.sorted {
            if $0.isCompleted != $1.isCompleted { return !$0.isCompleted }
            return $0.date > $1.date
        }
    }

    var body: some View {
        let sortedNotes = notes
        return VStack(alignment: .leading, spacing: 12) {
            if sortedNotes.isEmpty {
                Text("No practice notes yet.".localized)
                    .font(.subheadline.weight(.medium))
                Text("Write down a piece and what to work on next.".localized)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                LazyVStack(spacing: 0) {
                    ForEach(sortedNotes) { note in
                        HStack(alignment: .top, spacing: 8) {
                            Button {
                                _ = focusManager.updateTeacherNote(id: note.id, isCompleted: !note.isCompleted)
                            } label: {
                                Image(systemName: note.isCompleted ? "checkmark.circle.fill" : "circle")
                                    .font(.title3)
                                    .foregroundStyle(note.isCompleted ? Color.green : Color.secondary)
                                    .frame(width: 44, height: 44)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel((note.isCompleted ? "Mark as unfinished" : "Mark as completed").localized + ": " + note.title)
                            .accessibilityIdentifier("practiceNoteToggle-\(note.id)")

                            Button {
                                editingNote = note
                            } label: {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(note.title)
                                        .font(.subheadline.weight(.medium))
                                        .strikethrough(note.isCompleted)
                                        .foregroundStyle(note.isCompleted ? .secondary : .primary)
                                    if !note.content.isEmpty {
                                        Text(note.content)
                                            .font(.subheadline)
                                            .foregroundStyle(.secondary)
                                            .lineLimit(3)
                                    }
                                }
                                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                                .padding(.vertical, 8)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityIdentifier("practiceNoteEdit-\(note.id)")
                        }
                        if note.id != sortedNotes.last?.id { Divider() }
                    }
                }
            }

            Button {
                addingNote = true
            } label: {
                Label("Add Practice Note".localized, systemImage: "plus")
                    .frame(maxWidth: .infinity, minHeight: 44)
            }
            .buttonStyle(.bordered)
            .accessibilityIdentifier("addPracticeNote")
        }
        .sheet(isPresented: $addingNote) {
            PracticeNoteEditor(note: nil)
        }
        .sheet(item: $editingNote) { note in
            PracticeNoteEditor(note: note)
        }
    }
}

private struct PracticeNoteEditor: View {
    @EnvironmentObject private var focusManager: FocusManager
    @Environment(\.dismiss) private var dismiss
    let note: TeacherNote?
    @State private var title: String
    @State private var content: String
    @State private var completed: Bool
    @State private var confirmingDelete = false

    init(note: TeacherNote?) {
        self.note = note
        _title = State(initialValue: note?.title ?? "")
        _content = State(initialValue: note?.content ?? "")
        _completed = State(initialValue: note?.isCompleted ?? false)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Piece or title".localized, text: $title)
                        .accessibilityIdentifier("practiceNoteTitle")
                }
                Section("Practice focus".localized) {
                    TextEditor(text: $content)
                        .frame(minHeight: 150)
                        .accessibilityLabel("Practice focus".localized)
                        .accessibilityIdentifier("practiceNoteContent")
                }
                if note != nil {
                    Section {
                        Toggle("Completed".localized, isOn: $completed)
                    }
                    Section {
                        Button("Delete Practice Note".localized, role: .destructive) {
                            confirmingDelete = true
                        }
                    }
                }
            }
            .navigationTitle((note == nil ? "Add Practice Note" : "Edit Practice Note").localized)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel".localized) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save".localized) {
                        if let note {
                            _ = focusManager.updateTeacherNote(id: note.id,
                                title: title.trimmingCharacters(in: .whitespacesAndNewlines),
                                content: content, isCompleted: completed)
                        } else {
                            _ = focusManager.addTeacherNote(
                                title: title.trimmingCharacters(in: .whitespacesAndNewlines), content: content)
                        }
                        dismiss()
                    }
                    .disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .accessibilityIdentifier("savePracticeNote")
                }
            }
            .alert("Delete this practice note?".localized, isPresented: $confirmingDelete) {
                Button("Cancel".localized, role: .cancel) { }
                Button("Delete".localized, role: .destructive) {
                    if let note { focusManager.deleteTeacherNote(id: note.id) }
                    dismiss()
                }
            }
        }
    }
}
