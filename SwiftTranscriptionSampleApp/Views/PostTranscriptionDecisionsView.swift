import SwiftUI

struct PostTranscriptionDecisionsView: View {
    @Binding var form: SurgicalRequestForm
    let evidence: [String: String]
    let highlightEvidence: [String: HighlightedSpan]
    @State private var showingOPMEDetails = false
    @State private var isProcessing = false
    
    let onComplete: () -> Void
    let onCancel: () -> Void
    
    var body: some View {
        NavigationView {
            ScrollView {
                VStack(spacing: 24) {
                    headerSection
                    
                    // Only show decisions that weren't mentioned in transcription
                    if !form.ctiMentionedInTranscription {
                        CTIDecisionCard(
                            selection: $form.needsCTI,
                            evidenceSnippet: evidence["ctiFlag"],
                            highlight: highlightEvidence["ctiFlag"]
                        )
                    }
                    
                    if !form.precautionMentionedInTranscription {
                        PrecautionDecisionCard(
                            selection: $form.patientPrecaution,
                            evidenceSnippet: evidence["precautionFlag"],
                            highlight: highlightEvidence["precautionFlag"]
                        )
                    }
                    
                    // Always show OPME configuration for confirmation
                    OPMEConfigurationCard(
                        form: form,
                        procedureSnippet: evidence["procedureName"],
                        procedureHighlight: highlightEvidence["procedureName"],
                        showingDetails: $showingOPMEDetails
                    )
                    
                    // Additional fixed fields
                    AdditionalFieldsCard()
                    
                    actionButtons
                }
                .padding()
            }
            .navigationTitle("Informações Adicionais")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button(action: onCancel) {
                        Label("Pré-visualização", systemImage: "chevron.backward")
                    }
                }
            }
            .sheet(isPresented: $showingOPMEDetails) {
                OPMEDetailsView(form: form)
            }
        }
    }
    
    private var headerSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Confirme as informações abaixo", systemImage: "info.circle.fill")
                .font(.headline)
                .foregroundColor(.blue)
            
            Text("Selecione as opções que não foram mencionadas durante a transcrição.")
                .font(.subheadline)
                .foregroundColor(.secondary)
            
            if form.ctiMentionedInTranscription {
                if let highlight = highlightEvidence["ctiFlag"] {
                    HighlightedTranscriptView(highlight: highlight, accentColor: .orange)
                } else if let snippet = evidence["ctiFlag"], !snippet.isEmpty {
                    TranscriptSnippetView(snippet: snippet, title: "Trecho relacionado a CTI", accentColor: .orange)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(Color.blue.opacity(0.1))
        .cornerRadius(12)
    }
    
    private var actionButtons: some View {
        HStack(spacing: 16) {
            Button(action: onCancel) {
                Label("Cancelar", systemImage: "xmark")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
            
            Button(action: completeForm) {
                if isProcessing {
                    ProgressView()
                        .progressViewStyle(CircularProgressViewStyle(tint: .white))
                        .frame(maxWidth: .infinity)
                } else {
                    Label("Gerar Formulário", systemImage: "checkmark")
                        .frame(maxWidth: .infinity)
                }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(!isFormComplete || isProcessing)
        }
        .padding(.top)
    }
    
    private var isFormComplete: Bool {
        // Check if all required decisions have been made
        if !form.ctiMentionedInTranscription && form.needsCTI == nil {
            return false
        }
        if !form.precautionMentionedInTranscription && form.patientPrecaution == nil {
            return false
        }
        return true
    }
    
    private func completeForm() {
        isProcessing = true
        
        // Apply OPME configuration
        if let procedureName = form.fields.first(where: { $0.id == "procedureName" })?.value {
            let opmeConfig = OPMEConfiguration.getConfiguration(for: procedureName)
            form.needsOPME = opmeConfig.needed
            form.opmeSpecification = opmeConfig.items
        }
        
        // Format time to military format
        if let timeField = form.fields.firstIndex(where: { $0.id == "surgeryTime" }) {
            let originalTime = form.fields[timeField].value
            form.fields[timeField].value = MilitaryTimeFormatter.format(originalTime)
        }
        
        // Apply defaults for unmentioned fields
        if form.needsCTI == nil {
            form.needsCTI = false // Default to not needing CTI
        }
        if form.patientPrecaution == nil {
            form.patientPrecaution = false // Default to no precaution
        }
        
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            isProcessing = false
            onComplete()
        }
    }
}

// MARK: - CTI Decision Card

struct CTIDecisionCard: View {
    @Binding var selection: Bool?
    var evidenceSnippet: String?
    var highlight: HighlightedSpan?
    
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: "bed.double.fill")
                    .foregroundColor(.orange)
                Text("Necessidade de CTI")
                    .font(.headline)
            }
            
            if let highlight {
                HighlightedTranscriptView(highlight: highlight, accentColor: .orange)
            } else if let snippet = evidenceSnippet, !snippet.isEmpty {
                TranscriptSnippetView(snippet: snippet, accentColor: .orange)
            }
            
            Text("O paciente precisará de Centro de Terapia Intensiva?")
                .font(.subheadline)
                .foregroundColor(.secondary)
            
            HStack(spacing: 16) {
                SelectionButton(
                    title: "Não",
                    isSelected: selection == false,
                    color: .green
                ) {
                    withAnimation {
                        selection = false
                    }
                }
                
                SelectionButton(
                    title: "Sim",
                    isSelected: selection == true,
                    color: .orange
                ) {
                    withAnimation {
                        selection = true
                    }
                }
            }
        }
        .padding()
        .background(Color(.systemBackground))
        .cornerRadius(12)
        .shadow(radius: 2)
    }
}

// MARK: - Precaution Decision Card

struct PrecautionDecisionCard: View {
    @Binding var selection: Bool?
    var evidenceSnippet: String?
    var highlight: HighlightedSpan?
    
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundColor(.yellow)
                Text("Paciente em Precaução")
                    .font(.headline)
            }
            
            if let highlight {
                HighlightedTranscriptView(highlight: highlight, accentColor: .yellow)
            } else if let snippet = evidenceSnippet, !snippet.isEmpty {
                TranscriptSnippetView(snippet: snippet, accentColor: .yellow)
            }
            
            Text("O paciente requer precauções especiais?")
                .font(.subheadline)
                .foregroundColor(.secondary)
            
            HStack(spacing: 16) {
                SelectionButton(
                    title: "Não",
                    isSelected: selection == false,
                    color: .green
                ) {
                    withAnimation {
                        selection = false
                    }
                }
                
                SelectionButton(
                    title: "Sim",
                    isSelected: selection == true,
                    color: .yellow
                ) {
                    withAnimation {
                        selection = true
                    }
                }
            }
        }
        .padding()
        .background(Color(.systemBackground))
        .cornerRadius(12)
        .shadow(radius: 2)
    }
}

// MARK: - OPME Configuration Card

struct OPMEConfigurationCard: View {
    let form: SurgicalRequestForm
    var procedureSnippet: String?
    var procedureHighlight: HighlightedSpan?
    @Binding var showingDetails: Bool
    
    private var opmeConfig: OPMERequirement {
        if let procedureName = form.fields.first(where: { $0.id == "procedureName" })?.value {
            return OPMEConfiguration.getConfiguration(for: procedureName)
        }
        return OPMERequirement.none
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: "briefcase.fill")
                    .foregroundColor(.blue)
                Text("Configuração OPME")
                    .font(.headline)
                
                Spacer()
                
                if opmeConfig.needed {
                    Label("Automático", systemImage: "checkmark.circle.fill")
                        .font(.caption)
                        .foregroundColor(.green)
                }
            }
            
            if let highlight = procedureHighlight {
                HighlightedTranscriptView(highlight: highlight, accentColor: .blue)
            } else if let snippet = procedureSnippet, !snippet.isEmpty {
                TranscriptSnippetView(snippet: snippet, title: "Trecho do procedimento", accentColor: .blue)
            }
            
            if opmeConfig.needed {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Materiais necessários:")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                    
                    Text(opmeConfig.items)
                        .font(.body)
                        .padding()
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.blue.opacity(0.1))
                        .cornerRadius(8)
                    
                    Button(action: { showingDetails = true }) {
                        Label("Ver Detalhes", systemImage: "info.circle")
                            .font(.footnote)
                    }
                    .buttonStyle(.bordered)
                }
            } else {
                HStack {
                    Image(systemName: "xmark.circle")
                        .foregroundColor(.gray)
                    Text("OPME não necessário para este procedimento")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }
                .padding()
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(.systemGray6))
                .cornerRadius(8)
            }
        }
        .padding()
        .background(Color(.systemBackground))
        .cornerRadius(12)
        .shadow(radius: 2)
    }
}

// MARK: - Additional Fields Card

struct AdditionalFieldsCard: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: "doc.text.fill")
                    .foregroundColor(.gray)
                Text("Campos Padrão")
                    .font(.headline)
            }
            
            VStack(alignment: .leading, spacing: 8) {
                InfoRow(
                    icon: "shield.fill",
                    title: "Doença Infectocontagiosa",
                    value: "Não",
                    color: .green
                )
                
                InfoRow(
                    icon: "drop.fill",
                    title: "Reserva de Hemocomponentes",
                    value: "Não",
                    color: .green
                )
                
                InfoRow(
                    icon: "wrench.fill",
                    title: "Equipamentos Específicos",
                    value: "Não",
                    color: .green
                )
                
                InfoRow(
                    icon: "building.2.fill",
                    title: "Convênio",
                    value: "SUS",
                    color: .blue
                )
            }
            .padding()
            .background(Color(.systemGray6))
            .cornerRadius(8)
        }
        .padding()
        .background(Color(.systemBackground))
        .cornerRadius(12)
        .shadow(radius: 2)
    }
}

// MARK: - Helper Components

struct SelectionButton: View {
    let title: String
    let isSelected: Bool
    let color: Color
    let action: () -> Void
    
    var body: some View {
        Button(action: action) {
            HStack {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .foregroundColor(isSelected ? color : .gray)
                Text(title)
                    .fontWeight(isSelected ? .semibold : .regular)
            }
            .frame(maxWidth: .infinity)
            .padding()
            .background(isSelected ? color.opacity(0.1) : Color(.systemGray6))
            .cornerRadius(8)
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(isSelected ? color : Color.clear, lineWidth: 2)
            )
        }
        .buttonStyle(PlainButtonStyle())
    }
}

struct InfoRow: View {
    let icon: String
    let title: String
    let value: String
    let color: Color
    
    var body: some View {
        HStack {
            Image(systemName: icon)
                .foregroundColor(color)
                .frame(width: 20)
            
            Text(title)
                .font(.subheadline)
                .foregroundColor(.secondary)
            
            Spacer()
            
            Text(value)
                .font(.subheadline)
                .fontWeight(.medium)
                .foregroundColor(color)
        }
        .padding(.vertical, 4)
    }
}

// MARK: - OPME Details View

struct OPMEDetailsView: View {
    let form: SurgicalRequestForm
    @Environment(\.dismiss) private var dismiss
    
    private var procedureName: String {
        form.fields.first(where: { $0.id == "procedureName" })?.value ?? "Procedimento"
    }
    
    private var opmeConfig: OPMERequirement {
        OPMEConfiguration.getConfiguration(for: procedureName)
    }
    
    var body: some View {
        NavigationView {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    procedureSection
                    
                    if opmeConfig.needed {
                        materialsSection
                        notesSection
                    } else {
                        noOPMESection
                    }
                }
                .padding()
            }
            .navigationTitle("Detalhes OPME")
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
    
    private var procedureSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Procedimento", systemImage: "scissors")
                .font(.headline)
                .foregroundColor(.blue)
            
            Text(procedureName)
                .font(.title3)
                .fontWeight(.semibold)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(Color.blue.opacity(0.1))
        .cornerRadius(12)
    }
    
    private var materialsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Materiais Necessários", systemImage: "briefcase.fill")
                .font(.headline)
            
            let items = opmeConfig.items.components(separatedBy: "+").map { $0.trimmingCharacters(in: .whitespaces) }
            
            ForEach(items, id: \.self) { item in
                HStack(alignment: .top) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundColor(.green)
                        .font(.caption)
                        .padding(.top, 2)
                    
                    Text(item)
                        .font(.body)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(Color(.systemBackground))
        .cornerRadius(12)
        .shadow(radius: 2)
    }
    
    private var notesSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Observações", systemImage: "note.text")
                .font(.headline)
                .foregroundColor(.orange)
            
            Text("Estes materiais foram configurados automaticamente com base no procedimento selecionado. Verifique com o fornecedor a disponibilidade antes da cirurgia.")
                .font(.footnote)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(Color.orange.opacity(0.1))
        .cornerRadius(12)
    }
    
    private var noOPMESection: some View {
        VStack(spacing: 12) {
            Image(systemName: "xmark.circle")
                .font(.largeTitle)
                .foregroundColor(.gray)
            
            Text("OPME Não Necessário")
                .font(.headline)
            
            Text("Este procedimento não requer materiais OPME especiais.")
                .font(.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding()
        .background(Color(.systemGray6))
        .cornerRadius(12)
    }
}
