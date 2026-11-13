import email
import io
import json
import pathlib
import sys
import unittest
from email import policy

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))

import forwarder  # noqa: E402

FIXTURES = pathlib.Path(__file__).resolve().parent.parent / "tests" / "fixtures"


class StubS3:
    def __init__(self, objects):
        self.objects = objects
        self.calls = []

    def get_object(self, Bucket, Key):
        self.calls.append((Bucket, Key))
        return {"Body": io.BytesIO(self.objects[Key])}


class StubSes:
    def __init__(self):
        self.sent = []

    def send_raw_email(self, Source, Destinations, RawMessage):
        self.sent.append({"Source": Source, "Destinations": Destinations, "Data": RawMessage["Data"]})
        return {"MessageId": "stub"}


def ses_event(message_id, *recipients):
    return {"Records": [{"ses": {"mail": {"messageId": message_id}, "receipt": {"recipients": list(recipients)}}}]}


def parse(data):
    return email.message_from_bytes(data, policy=policy.default)


class BuildForwardTests(unittest.TestCase):
    def setUp(self):
        self.raw = (FIXTURES / "multipart-mixed-attachment.eml").read_bytes()
        self.out = parse(forwarder.build_forward(self.raw, "support@goom.life"))

    def test_from_is_the_recipient_address(self):
        self.assertEqual(self.out["From"].addresses[0].addr_spec, "support@goom.life")

    def test_from_display_name_names_the_original_sender(self):
        self.assertIn("René Dupont", self.out["From"].addresses[0].display_name)

    def test_reply_to_is_the_original_from_not_the_original_reply_to(self):
        self.assertEqual(self.out["Reply-To"].addresses[0].addr_spec, "rene@example.org")
        self.assertEqual(len(self.out.get_all("Reply-To")), 1)

    def test_x_original_from_carries_the_original_from(self):
        self.assertIn("rene@example.org", str(self.out["X-Original-From"]))

    def test_subject_is_kept(self):
        self.assertEqual(self.out["Subject"], "Export broken")

    def test_original_to_and_cc_are_kept(self):
        self.assertEqual(self.out["To"], "support@goom.life")
        self.assertEqual(self.out["Cc"], "other@example.org")

    def test_attachment_and_body_are_kept(self):
        attachments = list(self.out.iter_attachments())
        self.assertEqual([a.get_filename() for a in attachments], ["report.pdf"])
        self.assertTrue(attachments[0].get_content().startswith(b"%PDF-1.4"))
        self.assertIn("export link", self.out.get_body(("plain",)).get_content())
        self.assertIn("<a href", self.out.get_body(("html",)).get_content())

    def test_headers_ses_rejects_are_removed(self):
        raw = (FIXTURES / "multipart-quoted-printable.eml").read_bytes()
        out = parse(forwarder.build_forward(raw, "claude-test@goom.life"))
        for header in ("Return-Path", "Message-ID", "DKIM-Signature", "Sender"):
            self.assertIsNone(out[header], header)

    def test_spoofed_x_original_from_is_replaced(self):
        raw = b"From: a@example.org\r\nX-Original-From: forged@example.org\r\nSubject: s\r\n\r\nbody\r\n"
        out = parse(forwarder.build_forward(raw, "support@goom.life"))
        self.assertEqual(out.get_all("X-Original-From"), ["a@example.org"])

    def test_folded_from_does_not_inject_headers(self):
        raw = b"From: Mallory\r\n <m@example.org>\r\nSubject: s\r\n\r\nbody\r\n"
        data = forwarder.build_forward(raw, "support@goom.life")
        out = parse(data)
        self.assertEqual(str(out["X-Original-From"]), "Mallory <m@example.org>")

    def test_missing_from_sets_no_reply_to(self):
        raw = b"Subject: s\r\n\r\nbody\r\n"
        out = parse(forwarder.build_forward(raw, "support@goom.life"))
        self.assertIsNone(out["Reply-To"])
        self.assertEqual(out["From"].addresses[0].addr_spec, "support@goom.life")

    def test_output_uses_crlf(self):
        data = forwarder.build_forward(self.raw, "support@goom.life")
        self.assertNotIn(b"\n", data.replace(b"\r\n", b""))


class HandleTests(unittest.TestCase):
    def test_forwards_to_the_target_for_the_recipient(self):
        raw = (FIXTURES / "multipart-mixed-attachment.eml").read_bytes()
        s3 = StubS3({"goom.life/support/m1": raw})
        ses = StubSes()
        result = forwarder.handle(ses_event("m1", "Support@Goom.life"), s3, ses, "mail", {"support@goom.life": "owner@example.com"})
        self.assertEqual(s3.calls, [("mail", "goom.life/support/m1")])
        self.assertEqual(ses.sent[0]["Source"], "support@goom.life")
        self.assertEqual(ses.sent[0]["Destinations"], ["owner@example.com"])
        self.assertEqual(result, {"forwarded": ["goom.life/support/m1"]})

    def test_recipient_without_rule_is_not_forwarded(self):
        s3 = StubS3({})
        ses = StubSes()
        result = forwarder.handle(ses_event("m2", "claude-test@goom.life"), s3, ses, "mail", {"support@goom.life": "owner@example.com"})
        self.assertEqual(s3.calls, [])
        self.assertEqual(ses.sent, [])
        self.assertEqual(result, {"forwarded": []})

    def test_each_domain_sends_from_its_own_address(self):
        raw = b"From: a@example.org\r\nSubject: s\r\n\r\nbody\r\n"
        s3 = StubS3({"gideonogega.com/support/m3": raw})
        ses = StubSes()
        forwarder.handle(ses_event("m3", "support@gideonogega.com"), s3, ses, "mail", {"support@gideonogega.com": "owner@example.com"})
        self.assertEqual(ses.sent[0]["Source"], "support@gideonogega.com")
        self.assertIn(b"support@gideonogega.com", ses.sent[0]["Data"])


class LoadRulesTests(unittest.TestCase):
    def test_keys_are_lower_cased(self):
        self.assertEqual(forwarder.load_rules(json.dumps({"Support@Goom.Life": "o@example.com"})), {"support@goom.life": "o@example.com"})

    def test_empty_is_no_rules(self):
        self.assertEqual(forwarder.load_rules(None), {})

    def test_non_object_is_rejected(self):
        with self.assertRaises(ValueError):
            forwarder.load_rules("[]")


class ObjectKeyTests(unittest.TestCase):
    def test_key_is_domain_then_local_part(self):
        self.assertEqual(forwarder.object_key("Claude-Test@goom.life", "abc"), "goom.life/claude-test/abc")


if __name__ == "__main__":
    unittest.main()
