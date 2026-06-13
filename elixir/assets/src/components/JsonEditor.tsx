import CodeMirror from "@uiw/react-codemirror";
import { json } from "@codemirror/lang-json";

interface JsonEditorProps {
  value: string;
  onChange: (value: string) => void;
  readOnly?: boolean;
  ariaLabel?: string;
  ariaDescribedBy?: string;
}

export function JsonEditor({ value, onChange, readOnly, ariaLabel, ariaDescribedBy }: JsonEditorProps) {
  return (
    <CodeMirror
      value={value}
      onChange={onChange}
      extensions={[json()]}
      readOnly={readOnly}
      aria-label={ariaLabel}
      aria-describedby={ariaDescribedBy}
      basicSetup={{ lineNumbers: true }}
      minHeight="160px"
      className="rounded-md border text-sm"
    />
  );
}
