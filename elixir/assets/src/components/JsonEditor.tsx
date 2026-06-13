import CodeMirror from "@uiw/react-codemirror";
import { json } from "@codemirror/lang-json";

interface JsonEditorProps {
  value: string;
  onChange: (value: string) => void;
  readOnly?: boolean;
  ariaLabel?: string;
}

export function JsonEditor({ value, onChange, readOnly, ariaLabel }: JsonEditorProps) {
  return (
    <CodeMirror
      value={value}
      onChange={onChange}
      extensions={[json()]}
      readOnly={readOnly}
      aria-label={ariaLabel}
      basicSetup={{ lineNumbers: true }}
      minHeight="160px"
      className="rounded-md border text-sm"
    />
  );
}
