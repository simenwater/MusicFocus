const express = require('express');
const Badge = require('../models/Badge');
const auth = require('../middleware/auth');
const router = express.Router();

// 获取用户的所有勋章
router.get('/', auth, async (req, res) => {
  try {
    const badges = await Badge.find({ userId: req.user._id })
      .sort({ date: -1 });
    res.json(badges);
  } catch (error) {
    res.status(500).json({ message: error.message });
  }
});

// 获取指定日期的勋章
router.get('/date/:date', auth, async (req, res) => {
  try {
    const date = new Date(req.params.date);
    const startOfDay = new Date(date.setHours(0, 0, 0, 0));
    const endOfDay = new Date(date.setHours(23, 59, 59, 999));

    const badges = await Badge.find({
      userId: req.user._id,
      date: { $gte: startOfDay, $lte: endOfDay }
    });

    res.json(badges);
  } catch (error) {
    res.status(500).json({ message: error.message });
  }
});

// 创建新的勋章
router.post('/', auth, async (req, res) => {
  try {
    const badge = new Badge({
      ...req.body,
      userId: req.user._id
    });
    await badge.save();
    res.status(201).json(badge);
  } catch (error) {
    res.status(400).json({ message: error.message });
  }
});

// 更新勋章
router.patch('/:id', auth, async (req, res) => {
  try {
    const badge = await Badge.findOne({
      _id: req.params.id,
      userId: req.user._id
    });

    if (!badge) {
      return res.status(404).json({ message: '未找到该勋章' });
    }

    Object.assign(badge, req.body);
    await badge.save();
    res.json(badge);
  } catch (error) {
    res.status(400).json({ message: error.message });
  }
});

// 删除勋章
router.delete('/:id', auth, async (req, res) => {
  try {
    const badge = await Badge.findOneAndDelete({
      _id: req.params.id,
      userId: req.user._id
    });

    if (!badge) {
      return res.status(404).json({ message: '未找到该勋章' });
    }

    res.json({ message: '勋章已删除' });
  } catch (error) {
    res.status(500).json({ message: error.message });
  }
});

module.exports = router; 