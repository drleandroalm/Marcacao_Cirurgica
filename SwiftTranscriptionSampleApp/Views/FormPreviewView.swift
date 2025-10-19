import SwiftUI
import UIKit
import FoundationModels

@MainActor
struct FormPreviewView: View {
    @State private var extractionResult: ExtractionResult
    @State private var form: SurgicalRequestForm
    @State private var isRefining = false
    @State private var showingAlternatives: String? = nil
    @State private var editingFieldId: String? = nil
    @State private var validationResult: ValidationResult?
    @State private var showingComplianceDetails = false
    
    let onConfirm: (SurgicalRequestForm) -> Void
    let onRetry: () -> Void
    
    init(extractionResult: ExtractionResult, form: SurgicalRequestForm, onConfirm: @escaping (SurgicalRequestForm) -> Void, onRetry: @escaping () -> Void) {
        print("🎯 FormPreviewView initialized")
        print("  - Entities count: \(extractionResult.entities.count)")
        print("  - Entities received (redacted values):")
        for (index, entity) in extractionResult.entities.enumerated() {
            print("    \(index + 1). \(entity.fieldId): \(redactedValue(entity.value)) (confidence: \(Int(entity.confidence * 100))%)")
        }
        
        self._extractionResult = State(initialValue: extractionResult)
        self._form = State(initialValue: form)
        self.onConfirm = onConfirm
        self.onRetry = onRetry
    }
    
    var body: some View {
        NavigationView {
            VStack(spacing: 0) {
                overallConfidenceHeader
                
                ScrollView {
                    VStack(spacing: 16) {
                        extractedEntitiesSection
                        unprocessedTextSection
                        originalTranscriptionSection
                    }
                    .padding()
                }
                
                actionButtons
            }
            .navigationTitle("Pré-visualização")
            .navigationBarTitleDisplayMode(.inline)
            .task {
                // Initialize form with extracted values on the main actor
                let updatedForm = form
                for entity in extractionResult.entities {
                    if let fieldIndex = updatedForm.fields.firstIndex(where: { $0.id == entity.fieldId }) {
                        print("  ✅ Updating field '\(updatedForm.fields[fieldIndex].label)' with value: \(redactedValue(entity.value))")
                        updatedForm.fields[fieldIndex].value = sanitizeForStorage(updatedForm.fields[fieldIndex].fieldType, entity.value)
                    }
                }
                form = updatedForm
                performValidation()
            }
            .sheet(isPresented: Binding(
                get: { showingAlternatives != nil },
                set: { if !$0 { showingAlternatives = nil } }
            )) {
                if let fieldId = showingAlternatives {
                    AlternativesSheet(
                        fieldId: fieldId,
                        form: form,
                        extractionResult: extractionResult,
                        onUpdate: updateFieldValue
                    )
                }
            }
            .sheet(isPresented: Binding(
                get: { editingFieldId != nil },
                set: { if !$0 { editingFieldId = nil } }
            )) {
                if let fieldId = editingFieldId,
                   let idx = form.fields.firstIndex(where: { $0.id == fieldId }) {
                    FieldEditorSheet(field: $form.fields[idx]) { newValue in
                        updateFieldValue(fieldId, newValue)
                        performValidation()
                    }
                }
            }
            .sheet(isPresented: $showingComplianceDetails) {
                ComplianceDetailsView(validationResult: validationResult ?? ValidationResult(issues: [], overallConfidence: 0, fieldStatuses: [:]))
            }
        }
    }
    
    private func performValidation() {
        validationResult = ComplianceValidator.validate(form: form)
    }
    
    private var overallConfidenceHeader: some View {
        VStack(spacing: 8) {
            HStack {
                Image(systemName: confidenceIcon(extractionResult.confidence))
                    .foregroundColor(confidenceColor(extractionResult.confidence))
                
                Text("Confiança Geral: \(Int(extractionResult.confidence * 100))%")
                    .font(.headline)
                    .foregroundColor(confidenceColor(extractionResult.confidence))
                
                Spacer()
                
                if let validation = validationResult {
                    Button(action: { showingComplianceDetails = true }) {
                        HStack(spacing: 4) {
                            Image(systemName: validation.isValid ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                                .foregroundColor(validation.isValid ? .green : .orange)
                            Text(validation.issues.isEmpty ? "Validado" : "\(validation.issues.count) avisos")
                                .font(.caption)
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(validation.isValid ? Color.green.opacity(0.2) : Color.orange.opacity(0.2))
                        .cornerRadius(8)
                    }
                }
            }
            
            ProgressView(value: extractionResult.confidence)
                .tint(confidenceColor(extractionResult.confidence))
        }
        .padding()
        .background(confidenceColor(extractionResult.confidence).opacity(0.1))
    }
    
    private var extractedEntitiesSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Informações Extraídas")
                .font(.headline)
                .padding(.bottom, 8)
            
            ForEach(form.fields, id: \.id) { field in
                EntityPreviewCard(
                    field: field,
                    extractedEntity: extractionResult.entities.first { $0.fieldId == field.id },
                    complianceStatus: validationResult?.fieldStatuses[field.id],
                    isLowConfidence: form.lowConfidenceFieldIds.contains(field.id),
                    evidenceSnippet: form.evidenceSnippets[field.id],
                    highlight: form.highlightSpans[field.id],
                    onEdit: { editField(field.id) },
                    onShowAlternatives: { showingAlternatives = field.id },
                    onRefine: { refineField(field.id) }
                )
            }
        }
    }
    
    private var unprocessedTextSection: some View {
        Group {
            if !extractionResult.unprocessedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Texto Não Processado")
                        .font(.headline)
                        .foregroundColor(.orange)
                    
                    Text(extractionResult.unprocessedText)
                        .font(.body)
                        .padding()
                        .background(Color.orange.opacity(0.1))
                        .cornerRadius(8)
                        .overlay(
                            RoundedRectangle(cornerRadius: 8)
                                .stroke(Color.orange.opacity(0.3), lineWidth: 1)
                        )
                    
                    Text("Este texto pode conter informações importantes que não foram extraídas automaticamente.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
        }
    }
    
    private var originalTranscriptionSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Transcrição Original")
                .font(.headline)
            
            Text(getOriginalTranscription())
                .font(.footnote)
                .foregroundColor(.secondary)
                .padding()
                .background(Color(.systemGray6))
                .cornerRadius(8)
        }
    }
    
    private var actionButtons: some View {
        HStack(spacing: 16) {
            Button(action: onRetry) {
                Label("Tentar Novamente", systemImage: "arrow.clockwise")
                    .font(.footnote)
            }
            .buttonStyle(.bordered)
            
            Button(action: { onConfirm(form) }) {
                Label("Confirmar", systemImage: "checkmark")
                    .font(.footnote)
            }
            .buttonStyle(.borderedProminent)
        }
        .padding()
        .background(Color(.systemGray6))
    }
    
    private func confidenceIcon(_ confidence: Double) -> String {
        switch confidence {
        case 0.9...1.0: return "checkmark.circle.fill"
        case 0.7..<0.9: return "exclamationmark.triangle.fill"
        default: return "xmark.circle.fill"
        }
    }
    
    private func confidenceColor(_ confidence: Double) -> Color {
        switch confidence {
        case 0.9...1.0: return .green
        case 0.7..<0.9: return .orange
        default: return .red
        }
    }
    
    private func editField(_ fieldId: String) { editingFieldId = fieldId }
    
    private func refineField(_ fieldId: String) {
        guard let entity = extractionResult.entities.first(where: { $0.fieldId == fieldId }) else { return }
        
        isRefining = true
        Task {
            let refined = await RefinementQueue.shared.submit(entity: entity)
            await MainActor.run {
                defer { isRefining = false }
                guard let refined = refined else { return }
                if let fieldIndex = form.fields.firstIndex(where: { $0.id == fieldId }) {
                    form.fields[fieldIndex].value = refined.value
                    if let highlight = refined.span.flatMap({ span in
                        HighlightedSpan(
                            fieldId: refined.fieldId,
                            snippet: span.snippet,
                            context: refined.originalText,
                            start: span.start,
                            end: span.end,
                            confidence: refined.confidence
                        )
                    }) {
                        form.highlightSpans[fieldId] = highlight
                        form.evidenceSnippets[fieldId] = highlight.snippet
                    }
                }

                if let entityIndex = extractionResult.entities.firstIndex(where: { $0.fieldId == fieldId }) {
                    extractionResult.entities[entityIndex] = refined
                }
            }
        }
    }
    
    private func updateFieldValue(_ fieldId: String, _ newValue: String) {
        if let fieldIndex = form.fields.firstIndex(where: { $0.id == fieldId }) {
            form.fields[fieldIndex].value = newValue
        }
    }
    
    private func getOriginalTranscription() -> String {
        if let firstEntity = extractionResult.entities.first {
            return firstEntity.originalText
        } else if !extractionResult.unprocessedText.isEmpty {
            return extractionResult.unprocessedText
        } else {
            return "Sem transcrição disponível"
        }
    }
}

struct EntityPreviewCard: View {
    let field: TemplateField
    let extractedEntity: ExtractedEntity?
    let complianceStatus: ComplianceStatus?
    let isLowConfidence: Bool
    let evidenceSnippet: String?
    let highlight: HighlightedSpan?
    let onEdit: () -> Void
    let onShowAlternatives: () -> Void
    let onRefine: () -> Void
    
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: field.isComplete ? "checkmark.circle.fill" : "circle")
                    .foregroundColor(field.isComplete ? .green : .gray)
                
                Text(field.label)
                    .font(.headline)
                
                Spacer()
                
                if let status = complianceStatus {
                    ComplianceIndicator(status: status)
                }
                
                if let entity = extractedEntity {
                    ConfidenceBadge(confidence: entity.confidence)
                }
            }
            
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Valor:")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    
                    Text(displayValue(for: field))
                        .font(.body)
                        .foregroundColor(field.value.isEmpty ? .gray : .primary)
                }
                
                Spacer()
                
                VStack(spacing: 8) {
                    Button("Editar", action: onEdit)
                        .buttonStyle(.bordered)
                        .font(.caption)
                    
                    if let entity = extractedEntity, !entity.alternatives.isEmpty {
                        Button("Alternativas", action: onShowAlternatives)
                            .buttonStyle(.bordered)
                            .font(.caption)
                    }
                    
                    if extractedEntity != nil {
                        Button("Refinar", action: onRefine)
                            .buttonStyle(.bordered)
                            .font(.caption)
                    }
                }
            }

            if isLowConfidence {
                HStack {
                    Image(systemName: "eye.trianglebadge.exclamationmark")
                        .foregroundColor(.orange)
                    Text("Revise este valor – confiança baixa")
                        .font(.caption)
                        .foregroundColor(.orange)
                }
            }

            if !field.value.isEmpty && !field.validate() {
                HStack {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundColor(.red)
                    Text("Valor inválido para este campo")
                        .font(.caption)
                        .foregroundColor(.red)
                }
                // Special guidance for phone missing DDD
                if field.fieldType == .phone {
                    let digits = field.value.filter { $0.isNumber }
                    if digits.count < 10 {
                        Text("Adicione o DDD (ex: 31) — ficará (31) 9 xxxx-xxxx")
                            .font(.caption2)
                            .foregroundColor(.red)
                    }
                }
            }

            if let highlight {
                HighlightedTranscriptView(highlight: highlight)
            } else if let snippet = evidenceSnippet, !snippet.isEmpty {
                TranscriptSnippetView(snippet: snippet)
            }
        }
        .padding()
        .background(Color(.systemBackground))
        .cornerRadius(12)
        .shadow(radius: 2)
    }
}

// MARK: - Display helpers
private func displayValue(for field: TemplateField) -> String {
    if field.value.isEmpty { return field.placeholder }
    return field.formattedValue()
}

private func sanitizeForStorage(_ type: FieldType, _ raw: String) -> String {
    switch type {
    case .age:
        return raw.filter { $0.isNumber }
    case .date:
        return TemplateField(id: "tmp", label: "", placeholder: "", value: raw, fieldType: .date, isRequired: true).formattedValue()
    case .time:
        return MilitaryTimeFormatter.format(raw)
    case .duration:
        return DurationFormatter.format(raw)
    case .phone:
        var digits = raw.filter { $0.isNumber }
        if digits.first == "0" { digits.removeFirst() }
        return digits
    default:
        return raw
    }
}

// Redact sensitive values from logs
private func redactedValue(_ value: String) -> String {
    return "<len=\(value.count)>"
}

// MARK: - Field Editor Sheet
struct FieldEditorSheet: View {
    @Binding var field: TemplateField
    var onSave: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var draft: String = ""
    
    var body: some View {
        NavigationView {
            Form {
                Section(header: Text("\(field.label)")) {
                    TextField(field.placeholder, text: $draft)
                        .keyboardType(keyboardType)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled(true)
                }
                
                if field.fieldType == .phone {
                    let digits = draft.filter { $0.isNumber }
                    if digits.count < 10 {
                        Text("Adicione o DDD (ex: 31) para validar o telefone.")
                            .font(.caption)
                            .foregroundColor(.red)
                    }
                    Text("Pré-visualização: \(TemplateField(id: field.id, label: field.label, placeholder: field.placeholder, value: draft, fieldType: .phone, isRequired: field.isRequired).formattedValue())")
                        .font(.footnote)
                        .foregroundColor(.secondary)
                }
            }
            .navigationTitle("Editar Campo")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Cancelar") { dismiss() }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Salvar") {
                        field.value = normalized(draft)
                        onSave(field.value)
                        dismiss()
                    }.disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .onAppear { draft = field.value }
        }
    }
    
    private var keyboardType: UIKeyboardType {
        switch field.fieldType {
        case .number, .age, .phone, .time, .duration: return .numberPad
        case .date: return .numbersAndPunctuation
        default: return .default
        }
    }
    
    private func normalized(_ text: String) -> String {
        switch field.fieldType {
        case .age:
            let digits = text.filter { $0.isNumber }
            if let v = Int(digits) { return String(v) }
            return text
        case .date:
            return TemplateField(id: field.id, label: field.label, placeholder: field.placeholder, value: text, fieldType: .date, isRequired: field.isRequired).formattedValue()
        case .time:
            return MilitaryTimeFormatter.format(text)
        case .duration:
            return DurationFormatter.format(text)
        case .phone:
            return text.filter { $0.isNumber }
        default:
            return text
        }
    }
}

struct ConfidenceBadge: View {
    let confidence: Double
    
    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: iconName)
                .font(.caption)
            Text("\(Int(confidence * 100))%")
                .font(.caption)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(backgroundColor)
        .foregroundColor(textColor)
        .cornerRadius(12)
    }
    
    private var iconName: String {
        switch confidence {
        case 0.9...1.0: return "checkmark"
        case 0.7..<0.9: return "exclamationmark"
        default: return "xmark"
        }
    }
    
    private var backgroundColor: Color {
        switch confidence {
        case 0.9...1.0: return .green.opacity(0.2)
        case 0.7..<0.9: return .orange.opacity(0.2)
        default: return .red.opacity(0.2)
        }
    }
    
    private var textColor: Color {
        switch confidence {
        case 0.9...1.0: return .green
        case 0.7..<0.9: return .orange
        default: return .red
        }
    }
}

@MainActor
struct AlternativesSheet: View {
    let fieldId: String
    @State private var form: SurgicalRequestForm
    let extractionResult: ExtractionResult
    let onUpdate: (String, String) -> Void
    
    @Environment(\.dismiss) private var dismiss
    
    init(fieldId: String, form: SurgicalRequestForm, extractionResult: ExtractionResult, onUpdate: @escaping (String, String) -> Void) {
        self.fieldId = fieldId
        self._form = State(initialValue: form)
        self.extractionResult = extractionResult
        self.onUpdate = onUpdate
    }
    
    var body: some View {
        NavigationView {
            VStack(alignment: .leading, spacing: 16) {
                if let field = form.fields.first(where: { $0.id == fieldId }),
                   let entity = extractionResult.entities.first(where: { $0.fieldId == fieldId }) {
                    
                    Text(field.label)
                        .font(.headline)
                    
                    Text("Valor Atual:")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                    
                    Button(action: {}) {
                        Text(entity.value)
                            .font(.body)
                            .foregroundColor(.primary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding()
                            .background(Color.blue.opacity(0.1))
                            .cornerRadius(8)
                            .overlay(
                                RoundedRectangle(cornerRadius: 8)
                                    .stroke(Color.blue, lineWidth: 2)
                            )
                    }
                    
                    if !entity.alternatives.isEmpty {
                        Text("Alternativas:")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                            .padding(.top)
                        
                        ForEach(entity.alternatives, id: \.self) { alternative in
                            Button(action: {
                                onUpdate(fieldId, alternative)
                                dismiss()
                            }) {
                                Text(alternative)
                                    .font(.body)
                                    .foregroundColor(.primary)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding()
                                    .background(Color(.systemGray6))
                                    .cornerRadius(8)
                            }
                        }
                    }
                    
                    Spacer()
                }
            }
            .padding()
            .navigationTitle("Alternativas")
            .navigationBarTitleDisplayMode(.inline)
            .navigationBarBackButtonHidden(true)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Cancelar") {
                        dismiss()
                    }
                }
            }
        }
    }
}

struct ComplianceIndicator: View {
    let status: ComplianceStatus
    
    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: status.icon)
                .foregroundColor(status.color)
                .font(.caption)
            
            if status.hasAlternatives {
                Image(systemName: "chevron.down.circle")
                    .foregroundColor(.secondary)
                    .font(.caption2)
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background(status.color.opacity(0.1))
        .cornerRadius(6)
    }
}

struct ComplianceDetailsView: View {
    let validationResult: ValidationResult
    @Environment(\.dismiss) private var dismiss
    
    var body: some View {
        NavigationView {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    overallStatusCard
                    
                    if !validationResult.issues.isEmpty {
                        issuesSection
                    }
                    
                    fieldStatusesSection
                }
                .padding()
            }
            .navigationTitle("Detalhes de Conformidade")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Fechar") {
                        dismiss()
                    }
                }
            }
        }
    }
    
    private var overallStatusCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: validationResult.isValid ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                    .foregroundColor(validationResult.isValid ? .green : .orange)
                    .font(.title2)
                
                VStack(alignment: .leading) {
                    Text(validationResult.isValid ? "Formulário Válido" : "Atenção Necessária")
                        .font(.headline)
                    Text("Confiança Geral: \(Int(validationResult.overallConfidence * 100))%")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                
                Spacer()
            }
            
            ProgressView(value: validationResult.overallConfidence)
                .tint(validationResult.isValid ? .green : .orange)
        }
        .padding()
        .background(Color(.systemBackground))
        .cornerRadius(12)
        .shadow(radius: 2)
    }
    
    private var issuesSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Avisos e Sugestões")
                .font(.headline)
            
            ForEach(Array(validationResult.issues.enumerated()), id: \.offset) { _, issue in
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: issue.severity == .error ? "xmark.circle.fill" : 
                                     issue.severity == .warning ? "exclamationmark.triangle.fill" : 
                                     "info.circle.fill")
                        .foregroundColor(issue.severity.color)
                    
                    VStack(alignment: .leading, spacing: 4) {
                        Text(issue.field)
                            .font(.caption)
                            .foregroundColor(.secondary)
                        Text(issue.message)
                            .font(.body)
                        if let suggestion = issue.suggestion {
                            Text(suggestion)
                                .font(.caption)
                                .foregroundColor(.blue)
                        }
                    }
                    
                    Spacer()
                }
                .padding()
                .background(issue.severity.color.opacity(0.1))
                .cornerRadius(8)
            }
        }
    }
    
    private var fieldStatusesSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Status dos Campos")
                .font(.headline)
            
            ForEach(Array(validationResult.fieldStatuses.sorted(by: { $0.key < $1.key })), id: \.key) { fieldId, status in
                HStack {
                    Image(systemName: status.icon)
                        .foregroundColor(status.color)
                    
                    Text(fieldId.replacingOccurrences(of: "patient", with: "Paciente ")
                            .replacingOccurrences(of: "surgeon", with: "Cirurgião ")
                            .replacingOccurrences(of: "procedure", with: "Procedimento ")
                            .replacingOccurrences(of: "Name", with: ""))
                        .font(.body)
                    
                    Spacer()
                    
                    Text(status.description)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .padding(.vertical, 4)
            }
        }
        .padding()
        .background(Color(.systemGray6))
        .cornerRadius(8)
    }
}
