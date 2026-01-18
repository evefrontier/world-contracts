import { decodeCleverErrorCode, formatDecodedError, isValidAbortCode } from "./decoder.js";
import { parseMoveError } from "./parser.js";
import { getErrorInfo } from "./error-map.js";

const tabButtons = document.querySelectorAll(".tab-button");
const tabContents = document.querySelectorAll(".tab-content");

tabButtons.forEach((button) => {
    button.addEventListener("click", () => {
        const targetTab = button.getAttribute("data-tab");

        // Update active states
        tabButtons.forEach((btn) => btn.classList.remove("active"));
        tabContents.forEach((content) => content.classList.remove("active"));

        button.classList.add("active");
        const targetContent = document.getElementById(`${targetTab}-tab`);
        if (targetContent) {
            targetContent.classList.add("active");
        }
    });
});

function copyToClipboard(text: string, button: HTMLButtonElement) {
    navigator.clipboard
        .writeText(text)
        .then(() => {
            const originalText = button.textContent;
            button.textContent = "Copied!";
            button.classList.add("copied");
            setTimeout(() => {
                button.textContent = originalText;
                button.classList.remove("copied");
            }, 2000);
        })
        .catch((err) => {
            console.error("Failed to copy:", err);
            alert("Failed to copy to clipboard");
        });
}

// Abort Code Decoder
const abortCodeInput = document.getElementById("abort-code-input") as HTMLInputElement;
const decodeButton = document.getElementById("decode-button") as HTMLButtonElement;
const decoderOutput = document.getElementById("decoder-output") as HTMLPreElement;
const copyDecoderButton = document.getElementById("copy-decoder") as HTMLButtonElement;

async function handleDecode() {
    const input = abortCodeInput.value.trim();

    if (!input) {
        decoderOutput.textContent = "Please enter an abort code.";
        decoderOutput.className = "output-box error";
        return;
    }

    // Validate abort code format
    if (!isValidAbortCode(input)) {
        const formatHint =
            input.startsWith("0x") || input.startsWith("0X")
                ? "Hex codes must be exactly 16 hex digits (e.g., 0xC002005600040005)"
                : "Decimal codes must be valid numbers within u64 range";
        decoderOutput.textContent = `Error: Invalid abort code format "${input}". ${formatHint}.`;
        decoderOutput.className = "output-box error";
        return;
    }

    try {
        const decoded = decodeCleverErrorCode(input);
        const formatted = formatDecodedError(decoded);

        decoderOutput.textContent = formatted;
        decoderOutput.className = "output-box success";
    } catch (error) {
        const errorMsg = error instanceof Error ? error.message : "Invalid abort code format";
        decoderOutput.textContent = `Error: ${errorMsg}`;
        decoderOutput.className = "output-box error";
    }
}

decodeButton.addEventListener("click", handleDecode);
abortCodeInput.addEventListener("keypress", (e) => {
    if (e.key === "Enter") {
        handleDecode();
    }
});

copyDecoderButton.addEventListener("click", () => {
    copyToClipboard(decoderOutput.textContent || "", copyDecoderButton);
});

// Error String Parser
const errorStringInput = document.getElementById("error-string-input") as HTMLTextAreaElement;
const parseButton = document.getElementById("parse-button") as HTMLButtonElement;
const parserOutput = document.getElementById("parser-output") as HTMLPreElement;
const copyParserButton = document.getElementById("copy-parser") as HTMLButtonElement;

function handleParse() {
    const input = errorStringInput.value.trim();

    if (!input) {
        parserOutput.textContent = "Please enter an error string.";
        parserOutput.className = "output-box error";
        return;
    }

    try {
        const parsed = parseMoveError(input);

        if (!parsed) {
            parserOutput.textContent =
                "Error: Could not parse the error string. Please check the format.";
            parserOutput.className = "output-box error";
            return;
        }

        if (!isValidAbortCode(parsed.abortCode)) {
            parserOutput.textContent =
                `Error: Invalid abort code format "${parsed.abortCode}". ` +
                `Abort codes should be valid u64 values (8-16 hex digits for hex format).`;
            parserOutput.className = "output-box error";
            return;
        }

        // Get error constant name and message if available
        try {
            const errorInfo = getErrorInfo(parsed.moduleName, parsed.decodedError.error_code);
            if (errorInfo) {
                const errorMessage = errorInfo.errorMessage ? ` : ${errorInfo.errorMessage}` : "";
                parserOutput.textContent = `Error : ${parsed.moduleName}::${errorInfo.constantName}${errorMessage}`;
                parserOutput.className = "output-box success";
            } else {
                parserOutput.textContent =
                    `Error: No error constant found for module "${parsed.moduleName}" ` +
                    `with error code ${parsed.decodedError.error_code}. The abort code may be invalid ` +
                    `or the error is not defined in this module.`;
                parserOutput.className = "output-box error";
            }
        } catch (e) {
            const errorMsg = e instanceof Error ? e.message : "Unknown error";
            parserOutput.textContent = `Error: Could not lookup error constant. ${errorMsg}`;
            parserOutput.className = "output-box error";
        }
    } catch (error) {
        const errorMsg = error instanceof Error ? error.message : "Failed to parse error string";
        parserOutput.textContent = `Error: ${errorMsg}`;
        parserOutput.className = "output-box error";
    }
}

parseButton.addEventListener("click", handleParse);
copyParserButton.addEventListener("click", () => {
    copyToClipboard(parserOutput.textContent || "", copyParserButton);
});
