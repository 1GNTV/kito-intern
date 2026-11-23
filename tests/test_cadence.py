import math
import unittest

class SamplingTest(unittest.TestCase):
    def test_thirty_to_twenty_five_does_not_become_fifteen(self):
        indices = [math.floor((n / 30) * 25 + 0.001) for n in range(301)]
        accepted = [indices[0]] + [v for i, v in enumerate(indices[1:], 1) if v > indices[i - 1]]
        self.assertEqual(len(accepted), 251)
        self.assertTrue(all(b > a for a, b in zip(accepted, accepted[1:])))

    def test_fifteen_and_twenty_slot_counts(self):
        for fps in (15, 20):
            indices = [math.floor((n / 30) * fps + 0.001) for n in range(301)]
            self.assertEqual(len(set(indices)), fps * 10 + 1)

if __name__ == "__main__":
    unittest.main()
